using JuMP
using DataFrames
using CSV
using HiGHS
using Statistics
using LinearAlgebra
using Unicode

# arredondamento "meio para cima" (Julia usa arredondamento bancário em round)
arred(x) = floor(Int, x + 0.5)

# =====================================================================
# PARÂMETROS GERAIS
# =====================================================================
const TEMPO_LIMITE_S = 3600.0
const GAP_MIP        = 0.01     # 1%: em escala Suzano 5% seriam milhões
const RELAXAR_INTEIROS = false  # só vale com ESTRATEGIA = :direto
const MIP_ESFORCO_HEURISTICO = 0.3

# --- Estratégia de resolução ---
#   :duas_fases -> Fase 1: LP com todas as rotas; Fase 2: MIP só com as rotas usadas (+irmãs)
#   :direto     -> resolve uma vez com todas as rotas
const ESTRATEGIA           = :duas_fases
const FILTRO_DOMINANCIA    = true     # exato
const TEMPO_LIMITE_FASE1_S = 3600.0
const LIMIAR_USO_ROTA      = 1e-3     # rota é "usada" na fase 1 se navios (em algum mês) > limiar
const INCLUIR_IRMAS        = true
const IPM_CROSSOVER        = true     # true: solução básica -> seleção de rotas mais discriminante

# --- Escalas ---
const ESCALA_TON   = 1000.0
const ESCALA_MOEDA = 1000.0

# Pré-filtro heurístico (0 desliga). Ver sensibilidade_prefiltro() para medir o impacto.
const PREFILTRO_K        = 3
const DEMANDA_MINIMA_TON = 1.0
const MAX_VARIAVEIS      = 4_000_000

# Frota padrão quando não há dado (RDFrota.csv / MAX_NAVIOS): valor ARBITRÁRIO, avisa no log.
const FROTA_MAX_POR_ARMADOR = 5

# --- MODO TESTE ---
const MODO_TESTE                  = true
const TESTE_MAX_INSTANTES         = 4
const TESTE_MAX_ROTAS_POR_ARMADOR = 30
const TESTE_MAX_PRODUTOS          = 15
const TESTE_MAX_CLIENTES          = 30
const SOLVER_RELAXACAO = MODO_TESTE ? "simplex" : "ipm"

# --- Estoque de segurança nos PODs ---
const DIAS_ESTOQUE_SEGURANCA = 15
const DIAS_NO_MES            = 30
# :vendas        -> exigência = 15 dias das VENDAS reais do POD no mês seguinte (linear)
# :demanda_igual -> demanda do cliente dividida igualmente entre seus PODs (aproximação antiga)
const BASE_ESTOQUE_SEGURANCA = :vendas

# --- Balanceamento de cobertura entre PODs (penalidade suave, em % do preço médio) ---
const PEN_BAL_PCT          = 0.002    # 0 desliga
const BAL_DEMANDA_MIN_TON  = 500.0    # só balanceia PODs com demanda mensal >= isto

# --- Timing / capacidades / preços ---
const FABRICA_POL_MESMO_MES  = true   # frete fábrica->POL desprezível também no TEMPO
const RESTRINGIR_PICO_ESTOQUE = true  # capacidade vale para estoque anterior + descarga
const PRECO_POR_COORTE       = true   # demanda atrasada é vendida ao preço do mês da demanda
const VALOR_RESIDUAL_PCT     = 0.0    # valor do estoque final nos PODs (fração do preço médio). 0 = sem valor

# --- Desconto escalonado de frete marítimo ---
const FAIXAS_FRETE = [
    (0.00, 0.50, 0.00),
    (0.50, 0.75, 0.10),
    (0.75, 1.00, 0.25),
]

# --- Rotas multi-stop ---
const TEMPO_OPERACAO_PADRAO = 0
# true: a ocupação com que o navio CHEGA em cada POD respeita o calado daquele POD (fiel)
const CALADO_DESCARGA_POR_PARADA = true

# --- Custos e penalidades (PLACEHOLDERS: % do preço médio; substituir por dados reais) ---
const PCT_ESTOQUE_FABRICA = 0.010
const PCT_ESTOQUE_POL     = 0.006
const PCT_ESTOQUE_POD     = 0.003
const PCT_PEN_BACKLOG     = 0.02
const PCT_PEN_SS          = 0.05
const PCT_PEN_SPOT        = 0.30

# --- RESTRIÇÕES FLEXÍVEIS (elásticas) ---------------------------------------------------
# true: capacidades e metas "duras" viram restrições com folga penalizada. O modelo passa a ser
# SEMPRE factível e as folgas > 0 no log/CSV apontam exatamente qual restrição estava impossível.
# false: comportamento original (restrições duras).
const FLEXIBILIZAR         = true
const PCT_PEN_CAP_ESTOQUE  = 1.0    # excesso de estoque acima da capacidade (fim do mês e pico), por ton
const PCT_PEN_CAP_PORTO    = 1.0    # excesso de envio/recebimento acima da capacidade mensal do porto, por ton
const PCT_PEN_PROD_OCIOSA  = 0.5    # produção que deixa de ser feita (ociosidade da fábrica), por ton
const PCT_PEN_FROTA        = 1.0    # navio-mês acima da frota do armador, em múltiplos da receita de 1 carga média
const LIMIAR_RHS           = 1e-4   # (unid. escaladas) valores menores que isto viram 0: evita RHS ~5e-5 (numérica)
limpa(x) = abs(x) < LIMIAR_RHS ? 0.0 : x

# --- Saída, cenários e greenfield ---
const EXPORTAR_RESULTADOS      = true
const EXECUTAR_CENARIOS        = false   # true: roda estoque de segurança, expansão, recusa livre, greenfield
const TEMPO_LIMITE_CENARIO_S   = 900.0
const EXPANSAO_CAPACIDADE_PCT  = 0.20
const MARGEM_GREENFIELD        = 0.10    # prêmio de segurança sobre o frete estimado de rotas novas
const GREENFIELD_MAX_CANDIDATAS = 200


# =====================================================================
# CENÁRIO
# =====================================================================
Base.@kwdef struct Cenario
    nome::String = "base"
    dias_ss::Int = DIAS_ESTOQUE_SEGURANCA
    clientes_excluidos::Set{String} = Set{String}()
    fator_capacidade::Dict{String,Float64} = Dict{String,Float64}()   # fábrica => multiplicador
    recusar_livre::Bool = false          # true: sem penalidade por não atender (revela clientes deficitários)
    rotas_extras::Vector{Any} = Any[]    # rotas novas (greenfield) usadas na fase 1
end


# =====================================================================
# LEITURA DOS DADOS
# =====================================================================
const DIR       = @__DIR__
const DIR_SAIDA = joinpath(DIR, "saida")

const COLUNAS_NUMERICAS = ["PRECO_VENDA", "DEMANDA", "FRETE_POR_TON", "MIN_INTAKE", "MAX_INTAKE",
    "CALADO_DWT", "MAX_ESTOQUE", "CUSTO_ESTOQUE", "CUSTO_INLAND_POR_TON", "QTD_DISPONIVEL",
    "VOLUME_PRODUCAO", "TEMPO_IDA", "TEMPO_VOLTA", "TEMPO_OPERACAO",
    "CAPACIDADE_ENVIO", "CAPACIDADE_RECEBIMENTO", "MAX_NAVIOS", "FROTA_MAX", "QTD_TRANSITO"]

function converte_num(x)
    ismissing(x) && return missing
    x isa Number && return Float64(x)
    s = strip(string(x))
    isempty(s) && return missing
    return parse(Float64, replace(s, "," => "."))
end

function ler(nome)
    df = CSV.read(joinpath(DIR, nome), DataFrame; decimal = ',')
    for col in COLUNAS_NUMERICAS
        col in names(df) || continue
        eltype(df[!, col]) <: Union{Missing,Number} && continue
        df[!, col] = converte_num.(df[!, col])
    end
    return df
end

ler_opcional(nome) = isfile(joinpath(DIR, nome)) ? ler(nome) : nothing

ehtrue(x) = !ismissing(x) && (x isa Bool ? x :
            lowercase(strip(string(x))) in ("true", "1", "sim", "verdadeiro", "yes"))

function exigir(df, nome, cols)
    faltam = [c for c in cols if !(c in names(df))]
    isempty(faltam) || error("$nome: colunas ausentes: $(join(faltam, ", "))")
end

df_clientes       = ler("MDClientes.csv")
df_locais         = ler("MDLocais.csv")
df_produtos       = ler("MDProdutos.csv")
df_cap_fabricas   = ler("RDCapFabricas.csv")
df_local_produto  = ler("RDLocalProduto.csv")
df_demanda        = ler("RDDemanda.csv")
df_custo_inland   = ler("RDCustoInland.csv")
df_estoque_init   = ler("RDEstoqueInicial.csv")
df_armador_rotas  = ler("MDArmadorRotas.csv")
df_frota_opc      = ler_opcional("RDFrota.csv")
df_transito       = ler_opcional("RDTransitoInicial.csv")

exigir(df_clientes,      "MDClientes.csv",      ["COD_CLIENTE", "ATIVO"])
exigir(df_locais,        "MDLocais.csv",        ["COD_LOCAL", "TIPO"])
exigir(df_produtos,      "MDProdutos.csv",      ["FAMILIA_PRODUTO", "LINHA_PRODUTO", "ATIVO"])
exigir(df_cap_fabricas,  "RDCapFabricas.csv",   ["COD_LOCAL", "INSTANTE", "VOLUME_PRODUCAO"])
exigir(df_local_produto, "RDLocalProduto.csv",  ["COD_LOCAL", "LINHA_PRODUTO", "PRODUZ"])
exigir(df_demanda,       "RDDemanda.csv",       ["COD_CLIENTE", "FAMILIA_PRODUTO", "LINHA_PRODUTO", "INSTANTE", "DEMANDA", "PRECO_VENDA"])
exigir(df_custo_inland,  "RDCustoInland.csv",   ["COD_CLIENTE", "COD_LOCAL", "CUSTO_INLAND_POR_TON"])
exigir(df_estoque_init,  "RDEstoqueInicial.csv", ["COD_LOCAL", "FAMILIA_PRODUTO", "LINHA_PRODUTO", "QTD_DISPONIVEL"])
exigir(df_armador_rotas, "MDArmadorRotas.csv",  ["COD_ARMADOR", "COD_LOCAL_ORIGENS", "COD_LOCAL_DESTINOS",
                                                 "TEMPO_IDA", "FRETE_POR_TON", "MIN_INTAKE", "MAX_INTAKE"])
df_frota_opc === nothing || exigir(df_frota_opc, "RDFrota.csv", ["COD_ARMADOR", "MAX_NAVIOS"])
df_transito  === nothing || exigir(df_transito, "RDTransitoInicial.csv",
                                   ["COD_LOCAL", "FAMILIA_PRODUTO", "LINHA_PRODUTO", "INSTANTE", "QTD_TRANSITO"])

# ---------- MODO TESTE: amostra de rotas por armador ----------
if MODO_TESTE && TESTE_MAX_ROTAS_POR_ARMADOR > 0
    partes = DataFrame[]
    for g in groupby(df_armador_rotas, :COD_ARMADOR)
        n = nrow(g)
        m = max(TESTE_MAX_ROTAS_POR_ARMADOR, 2)
        idx = n <= m ? collect(1:n) : unique(round.(Int, range(1, n; length = m)))
        push!(partes, DataFrame(g[idx, :]))
    end
    global df_armador_rotas = reduce(vcat, partes)
end

# ---------- ESCALA: toneladas -> unidades de ESCALA_TON toneladas ----------
function escalar!(df, cols, fator)
    for col in cols
        col in names(df) || continue
        df[!, col] = df[!, col] .* fator
    end
end
if ESCALA_TON != 1.0 || ESCALA_MOEDA != 1.0
    escalar!(df_demanda,      ["DEMANDA"],                              1 / ESCALA_TON)
    escalar!(df_demanda,      ["PRECO_VENDA"],                          ESCALA_TON / ESCALA_MOEDA)
    escalar!(df_cap_fabricas, ["VOLUME_PRODUCAO"],                      1 / ESCALA_TON)
    escalar!(df_estoque_init, ["QTD_DISPONIVEL"],                       1 / ESCALA_TON)
    escalar!(df_locais,       ["MAX_ESTOQUE", "CALADO_DWT",
                               "CAPACIDADE_ENVIO", "CAPACIDADE_RECEBIMENTO"], 1 / ESCALA_TON)
    escalar!(df_locais,       ["CUSTO_ESTOQUE"],                        ESCALA_TON / ESCALA_MOEDA)
    escalar!(df_armador_rotas, ["MIN_INTAKE", "MAX_INTAKE"],            1 / ESCALA_TON)
    escalar!(df_armador_rotas, ["FRETE_POR_TON"],                       ESCALA_TON / ESCALA_MOEDA)
    escalar!(df_custo_inland, ["CUSTO_INLAND_POR_TON"],                 ESCALA_TON / ESCALA_MOEDA)
    df_transito === nothing || escalar!(df_transito, ["QTD_TRANSITO"],  1 / ESCALA_TON)
end

divide(x) = String.(strip.(split(string(x), ";")))


# =====================================================================
# CONJUNTOS
# =====================================================================
L    = String.(unique(df_locais.COD_LOCAL))
T    = sort(unique(df_cap_fabricas.INSTANTE))
if MODO_TESTE && TESTE_MAX_INSTANTES > 0
    global T = T[1:min(TESTE_MAX_INSTANTES, length(T))]
end
t0   = first(T)
tN   = last(T)
Tset = Set(T)
if MODO_TESTE
    global df_demanda = filter(row -> row.INSTANTE in Tset, df_demanda)
end

C    = String.(filter(row -> ehtrue(row.ATIVO), df_clientes).COD_CLIENTE)
if MODO_TESTE && TESTE_MAX_CLIENTES > 0 && length(C) > TESTE_MAX_CLIENTES
    dem_cli = Dict{String,Float64}()
    for row in eachrow(df_demanda)
        c = String(row.COD_CLIENTE)
        dem_cli[c] = get(dem_cli, c, 0.0) + coalesce(row.DEMANDA, 0.0)
    end
    sort!(C; by = c -> -get(dem_cli, c, 0.0))
    global C = C[1:TESTE_MAX_CLIENTES]
end
Cset = Set(C)

F   = String.(filter(row -> String(row.TIPO) == "Fabrica", df_locais).COD_LOCAL)
POL = String.(filter(row -> String(row.TIPO) == "POL",     df_locais).COD_LOCAL)
POD = String.(filter(row -> String(row.TIPO) == "POD",     df_locais).COD_LOCAL)
PODset = Set(POD)
tipo_local = Dict(String(row.COD_LOCAL) => String(row.TIPO) for row in eachrow(df_locais))

A = unique(String.(df_armador_rotas.COD_ARMADOR))

# Produtos ativos, identificados por um índice inteiro p
df_prod_ativos = filter(row -> ehtrue(row.ATIVO), df_produtos)
if MODO_TESTE && TESTE_MAX_PRODUTOS > 0 && nrow(df_prod_ativos) > TESTE_MAX_PRODUTOS
    chave_prod = row -> (String(row.FAMILIA_PRODUTO), String(row.LINHA_PRODUTO))
    dem_prod = Dict{Tuple{String,String},Float64}()
    for row in eachrow(df_demanda)
        String(row.COD_CLIENTE) in Cset || continue
        k = chave_prod(row)
        dem_prod[k] = get(dem_prod, k, 0.0) + coalesce(row.DEMANDA, 0.0)
    end
    ordem = sortperm([-get(dem_prod, chave_prod(row), 0.0) for row in eachrow(df_prod_ativos)])
    global df_prod_ativos = df_prod_ativos[sort(ordem[1:TESTE_MAX_PRODUTOS]), :]
end
prod_id   = [(String(row.FAMILIA_PRODUTO), String(row.LINHA_PRODUTO)) for row in eachrow(df_prod_ativos)]
P         = 1:length(prod_id)
linha_de  = [x[2] for x in prod_id]
idx_produto = Dict(prod_id[p] => p for p in P)

# (1) Fábricas x linhas de produto: só existem variáveis de produção para pares permitidos
FabricaLinhas = Set((String(row.COD_LOCAL), String(row.LINHA_PRODUTO))
                    for row in eachrow(df_local_produto) if ehtrue(row.PRODUZ))
FP    = [(f, p) for f in F for p in P if (f, linha_de[p]) in FabricaLinhas]
FPset = Set(FP)

# (2) Cliente só recebe por PODs específicos
ClientePODs = unique([(String(row.COD_CLIENTE), String(row.COD_LOCAL))
                      for row in eachrow(df_custo_inland)
                      if String(row.COD_CLIENTE) in Cset && String(row.COD_LOCAL) in PODset])
pods_do_cliente = Dict(c   => String[] for c in C)
clientes_do_pod = Dict(pod => String[] for pod in POD)
for (c, pod) in ClientePODs
    push!(pods_do_cliente[c], pod)
    push!(clientes_do_pod[pod], c)
end


# =====================================================================
# [M8] FROTA: lida de dados (com aviso quando usa o valor padrão)
# =====================================================================
frota_base = Dict{String,Int}()                 # armador -> limite constante
frota_mes  = Dict{Tuple{String,Int},Int}()      # (armador, instante) -> limite do mês
for col in ("MAX_NAVIOS", "FROTA_MAX")
    hasproperty(df_armador_rotas, Symbol(col)) || continue
    for row in eachrow(df_armador_rotas)
        v = row[Symbol(col)]
        ismissing(v) && continue
        a = String(row.COD_ARMADOR)
        frota_base[a] = max(get(frota_base, a, 0), arred(v))
    end
end
if df_frota_opc !== nothing
    for row in eachrow(df_frota_opc)
        a = String(row.COD_ARMADOR)
        ismissing(row.MAX_NAVIOS) && continue
        v = arred(row.MAX_NAVIOS)
        if hasproperty(df_frota_opc, :INSTANTE) && !ismissing(row.INSTANTE)
            frota_mes[(a, round(Int, row.INSTANTE))] = v
        else
            frota_base[a] = v
        end
    end
end
if isempty(frota_base) && isempty(frota_mes)
    @warn "Nenhum dado de frota (RDFrota.csv ou coluna MAX_NAVIOS em MDArmadorRotas.csv): " *
          "usando FROTA_MAX_POR_ARMADOR = $FROTA_MAX_POR_ARMADOR para TODOS os armadores (premissa arbitrária)."
end
frota_max(a, t) = get(frota_mes, (a, t), get(frota_base, a, FROTA_MAX_POR_ARMADOR))
function calc_teto(a)
    m = get(frota_base, a, FROTA_MAX_POR_ARMADOR)
    for ((aa, _), v) in frota_mes
        aa == a && (m = max(m, v))
    end
    return m
end
frota_teto = Dict(a => calc_teto(a) for a in A)


# =====================================================================
# [M8] MAPEAMENTO FÁBRICA -> POL (lido dos dados; validação explícita)
# =====================================================================
norm_nome(s) = lowercase(replace(Unicode.normalize(string(s); stripmark = true), r"[^A-Za-z0-9]" => ""))

# Tabela do enunciado (usada só se MDLocais.csv não tiver coluna de POL), casada por nome normalizado
const FABRICA_POL_ENUNCIADO = Dict(
    "Suzano" => "Santos", "Tres Lagoas" => "Santos", "Ribas do Rio Pardo" => "Santos",
    "Limeira" => "Santos", "Jacarei" => "Santos",
    "Mucuri" => "Portocel", "Aracruz" => "Portocel", "Veracel" => "Portocel",
    "Imperatriz" => "Itaqui",
)

function construir_fabrica_pol()
    mapa = Dict{String,String}()
    for col in ("COD_POL", "POL", "COD_LOCAL_POL", "PORTO_ORIGEM")
        hasproperty(df_locais, Symbol(col)) || continue
        for row in eachrow(df_locais)
            String(row.TIPO) == "Fabrica" || continue
            v = row[Symbol(col)]
            ismissing(v) && continue
            mapa[String(row.COD_LOCAL)] = String(v)
        end
        if !isempty(mapa)
            println("Mapeamento fábrica -> POL lido da coluna ", col, " de MDLocais.csv")
            break
        end
    end
    if isempty(mapa)
        ref = [(norm_nome(k), v) for (k, v) in FABRICA_POL_ENUNCIADO]
        for f in F
            nf = norm_nome(f)
            for (k, v) in ref
                if nf == k || startswith(nf, k) || startswith(k, nf)
                    mapa[f] = v
                    break
                end
            end
        end
        println("Mapeamento fábrica -> POL: tabela do enunciado casada por nome (sem coluna COD_POL).")
    end
    faltando = [f for f in F if !haskey(mapa, f)]
    isempty(faltando) || error("Fábricas sem POL definido: $(join(faltando, ", ")). " *
                               "Adicione a coluna COD_POL em MDLocais.csv. POLs disponíveis: $(join(POL, ", "))")
    for f in F
        v = mapa[f]
        if !(v in POL)
            nv = norm_nome(v)
            cand = [pl for pl in POL if norm_nome(pl) == nv || startswith(norm_nome(pl), nv) || startswith(nv, norm_nome(pl))]
            length(cand) == 1 || error("Fábrica $f: POL '$v' não encontrado entre os POLs ($(join(POL, ", ")))")
            mapa[f] = cand[1]
        end
    end
    return mapa
end
FabricaPOL = construir_fabrica_pol()


# =====================================================================
# PARÂMETROS
# =====================================================================
demanda     = Dict{Tuple{String,Int,Int},Float64}()
preco_venda = Dict{Tuple{String,Int,Int},Float64}()
for row in eachrow(df_demanda)
    c   = String(row.COD_CLIENTE)
    key = (String(row.FAMILIA_PRODUTO), String(row.LINHA_PRODUTO))
    (c in Cset && haskey(idx_produto, key)) || continue
    row.INSTANTE in Tset || continue
    k = (c, idx_produto[key], row.INSTANTE)
    d = coalesce(row.DEMANDA, 0.0)
    d >= DEMANDA_MINIMA_TON / ESCALA_TON && (demanda[k] = get(demanda, k, 0.0) + d)
    ismissing(row.PRECO_VENDA) || (preco_venda[k] = row.PRECO_VENDA)
end

# preço do mês t (último preço conhecido até t) - usado só fora do modo por coortes
function preco_mes(c, p, t)
    for tt in t:-1:t0
        haskey(preco_venda, (c, p, tt)) && return preco_venda[(c, p, tt)]
    end
    return 0.0
end

custo_inland = Dict((String(row.COD_CLIENTE), String(row.COD_LOCAL)) => row.CUSTO_INLAND_POR_TON
                    for row in eachrow(df_custo_inland))

estoque_inicial = Dict{Tuple{String,Int},Float64}()
for row in eachrow(df_estoque_init)
    key = (String(row.FAMILIA_PRODUTO), String(row.LINHA_PRODUTO))
    haskey(idx_produto, key) || continue
    estoque_inicial[(String(row.COD_LOCAL), idx_produto[key])] = coalesce(row.QTD_DISPONIVEL, 0.0)
end

volume_producao = Dict((String(row.COD_LOCAL), row.INSTANTE) => row.VOLUME_PRODUCAO
                       for row in eachrow(df_cap_fabricas))

# Calado/DWT, estoque máximo, capacidades de envio/recebimento, tempo de operação
caladoDWT   = Dict{String,Float64}()
max_estoque = Dict{String,Float64}()
cap_envio   = Dict{String,Float64}()
cap_receb   = Dict{String,Float64}()
oper_loc    = Dict{String,Int}()
for row in eachrow(df_locais)
    loc = String(row.COD_LOCAL)
    if String(row.TIPO) in ("POL", "POD") && !ismissing(row.CALADO_DWT) && isfinite(row.CALADO_DWT)
        caladoDWT[loc] = row.CALADO_DWT
    end
    if !ismissing(row.MAX_ESTOQUE) && isfinite(row.MAX_ESTOQUE)
        max_estoque[loc] = row.MAX_ESTOQUE
    end
    if hasproperty(df_locais, :CAPACIDADE_ENVIO) && !ismissing(row.CAPACIDADE_ENVIO) && isfinite(row.CAPACIDADE_ENVIO)
        cap_envio[loc] = row.CAPACIDADE_ENVIO
    end
    if hasproperty(df_locais, :CAPACIDADE_RECEBIMENTO) && !ismissing(row.CAPACIDADE_RECEBIMENTO) && isfinite(row.CAPACIDADE_RECEBIMENTO)
        cap_receb[loc] = row.CAPACIDADE_RECEBIMENTO
    end
    if hasproperty(df_locais, :TEMPO_OPERACAO) && !ismissing(row.TEMPO_OPERACAO)
        oper_loc[loc] = arred(row.TEMPO_OPERACAO)
    end
end
tempo_oper(loc) = get(oper_loc, loc, TEMPO_OPERACAO_PADRAO)
if isempty(cap_envio) && isempty(cap_receb)
    @info "Sem capacidades de envio/recebimento (colunas CAPACIDADE_ENVIO/CAPACIDADE_RECEBIMENTO em MDLocais.csv): restrição não aplicada."
end

# [M9] Trânsito inicial (carga que já saiu antes do horizonte): (POD, produto, instante de chegada) -> ton
transito_inicial = Dict{Tuple{String,Int,Int},Float64}()
if df_transito !== nothing
    for row in eachrow(df_transito)
        key = (String(row.FAMILIA_PRODUTO), String(row.LINHA_PRODUTO))
        haskey(idx_produto, key) || continue
        loc = String(row.COD_LOCAL)
        loc in PODset || continue
        ta = round(Int, row.INSTANTE)
        ta in Tset || continue
        k = (loc, idx_produto[key], ta)
        transito_inicial[k] = get(transito_inicial, k, 0.0) + coalesce(row.QTD_TRANSITO, 0.0)
    end
    println("Trânsito inicial carregado: ", length(transito_inicial), " registros.")
end

# ---------------------------------------------------------------------
# Custos de armazenagem e penalidades (PLACEHOLDERS quando não vêm dos dados)
# ---------------------------------------------------------------------
preco_medio = isempty(preco_venda) ? 1.0 : mean(values(preco_venda))

const CUSTO_ESTOQUE_FABRICA     = PCT_ESTOQUE_FABRICA * preco_medio
const CUSTO_ESTOQUE_ARMAZEM_EXT = PCT_ESTOQUE_POL * preco_medio
const CUSTO_ESTOQUE_POD         = PCT_ESTOQUE_POD * preco_medio

const PEN_BACKLOG      = PCT_PEN_BACKLOG * preco_medio
const PEN_SS           = PCT_PEN_SS * preco_medio
const PEN_SPOT         = PCT_PEN_SPOT * preco_medio
const PEN_BALANCEAMENTO = PEN_BAL_PCT * preco_medio
const PEN_CAP_ESTOQUE   = PCT_PEN_CAP_ESTOQUE * preco_medio
const PEN_CAP_PORTO     = PCT_PEN_CAP_PORTO * preco_medio
const PEN_PROD_OCIOSA   = PCT_PEN_PROD_OCIOSA * preco_medio

custo_estoque_tipo = Dict(
    "Fabrica"        => CUSTO_ESTOQUE_FABRICA,
    "POL"            => CUSTO_ESTOQUE_ARMAZEM_EXT,
    "ArmazemExterno" => CUSTO_ESTOQUE_ARMAZEM_EXT,
    "POD"            => CUSTO_ESTOQUE_POD,
)
custo_estoque = Dict{String,Float64}()
for row in eachrow(df_locais)
    loc = String(row.COD_LOCAL)
    if hasproperty(df_locais, :CUSTO_ESTOQUE) && !ismissing(row.CUSTO_ESTOQUE)
        custo_estoque[loc] = row.CUSTO_ESTOQUE
    else
        custo_estoque[loc] = get(custo_estoque_tipo, tipo_local[loc], 0.0)
    end
end
if !hasproperty(df_locais, :CUSTO_ESTOQUE) || any(ismissing, df_locais.CUSTO_ESTOQUE)
    @warn "CUSTO_ESTOQUE ausente em MDLocais.csv para alguns locais: usando PLACEHOLDERS (% do preço médio). " *
          "Penalidades PEN_SS / PEN_SPOT / PEN_BACKLOG também são placeholders: interprete o lucro operacional, não o objetivo."
end


# =====================================================================
# (4) ROTAS MULTI-STOP
#     carrega em origens[1], origens[2], ... (POLs) no instante de partida t
#     descarrega em destinos[1], destinos[2], ... (PODs) com chegada em t + lag_desc[k]
#     Colunas opcionais: TEMPO_PARADAS (tempos acumulados por destino, ";"), TEMPO_VOLTA
# =====================================================================
rotas = NamedTuple[]
for (i, row) in enumerate(eachrow(df_armador_rotas))
    origens  = divide(row.COD_LOCAL_ORIGENS)
    destinos = divide(row.COD_LOCAL_DESTINOS)
    ida      = arred(row.TEMPO_IDA)
    volta    = (hasproperty(df_armador_rotas, :TEMPO_VOLTA) && !ismissing(row.TEMPO_VOLTA)) ?
               arred(row.TEMPO_VOLTA) : ida
    n = length(destinos)

    if hasproperty(df_armador_rotas, :TEMPO_PARADAS) && !ismissing(row.TEMPO_PARADAS)
        base = parse.(Int, divide(row.TEMPO_PARADAS))
        length(base) == n || error("Rota $i: TEMPO_PARADAS precisa ter uma entrada por destino")
    else
        base = [arred(ida * k / n) for k in 1:n]     # [M10] meio para cima
    end

    acum = sum(tempo_oper(o) for o in origens)
    lag_desc = Int[]
    for k in 1:n
        acum += tempo_oper(destinos[k])
        push!(lag_desc, base[k] + acum)
    end
    issorted(lag_desc) || error("Rota $i: tempos de chegada nos PODs fora de ordem")

    ciclo = max(1, ida + volta + sum(tempo_oper(l) for l in vcat(origens, destinos)))

    push!(rotas, (id = i, armador = String(row.COD_ARMADOR),
                  origens = origens, destinos = destinos,
                  frete = row.FRETE_POR_TON,
                  min_in = row.MIN_INTAKE, max_in = row.MAX_INTAKE,
                  lag_desc = lag_desc, ciclo = ciclo, ida = ida, volta = volta))
end

for r in rotas
    for o in r.origens
        o in POL || error("Rota $(r.id): origem $o não é POL")
    end
    for d in r.destinos
        d in POD || error("Rota $(r.id): destino $d não é POD")
    end
end

@assert isapprox(sum(f[2] - f[1] for f in FAIXAS_FRETE), 1.0) "FAIXAS_FRETE deve cobrir 0–100%"


# =====================================================================
# FILTRO DE ROTAS (exato) E PRÉ-FILTRO (heurístico)
# =====================================================================
# Dominância exata: mesmo armador, origens/destinos (na ordem), tempos, ciclo e intake -> fica a mais barata.
function filtrar_dominancia(rs)
    melhor = Dict{Any,Int}()
    for (i, r) in enumerate(rs)
        sig = (r.armador, Tuple(r.origens), Tuple(r.destinos), Tuple(r.lag_desc), r.ciclo, r.min_in, r.max_in)
        if !haskey(melhor, sig) || r.frete < rs[melhor[sig]].frete
            melhor[sig] = i
        end
    end
    return rs[sort(collect(values(melhor)))]
end

# Renumera os ids (1..N) para indexar o modelo; guarda o id original em id_orig (rotas novas: id negativo)
renumerar(rs) = [merge(r, (id = k, id_orig = get(r, :id_orig, r.id))) for (k, r) in enumerate(rs)]

# Mantém as K rotas mais baratas de cada corredor (armador, POL, POD, tempo de chegada, ciclo, intake).
function prefiltro_por_corredor(rs, k)
    k <= 0 && return rs
    grupos = Dict{Any,Vector{Tuple{Float64,Int}}}()
    for (i, r) in enumerate(rs)
        for o in r.origens, (j, d) in enumerate(r.destinos)
            chave = (r.armador, o, d, r.lag_desc[j], r.ciclo, r.min_in, r.max_in)
            push!(get!(grupos, chave, Tuple{Float64,Int}[]), (Float64(r.frete), i))
        end
    end
    manter = Set{Int}()
    for (_, lst) in grupos
        sort!(lst)
        for x in first(lst, k)
            push!(manter, x[2])
        end
    end
    return rs[sort(collect(manter))]
end

rotas_dominadas = renumerar(FILTRO_DOMINANCIA ? filtrar_dominancia(rotas) : rotas)
println("Rotas no arquivo: ", length(rotas), " -> após filtro de dominância (exato): ", length(rotas_dominadas))
rotas_base = rotas_dominadas
if PREFILTRO_K > 0
    n_antes_pf = length(rotas_dominadas)
    rotas_base = renumerar(prefiltro_por_corredor(rotas_dominadas, PREFILTRO_K))
    println("Pré-filtro por corredor (K = ", PREFILTRO_K, "): ", n_antes_pf, " -> ", length(rotas_base), " rotas")
end


# =====================================================================
# MODELO (fluxo de produto por TRECHO, não por rota)
#   y[rota, origem k, destino j, t] (ton) por segmento; produtos fluem por trecho (POL, POD, tempo).
#   Frota contada por armador. Variáveis só existem onde há produto viável e chegada no horizonte.
# =====================================================================
function construir_modelo(rotas, relaxar::Bool, tempo_limite::Float64, cen::Cenario)
nP = length(P); nT = length(T); K = length(FAIXAS_FRETE)
cobertura = cen.dias_ss / DIAS_NO_MES

# ---------------- Demanda do cenário ----------------
excl = cen.clientes_excluidos
demanda_c = Dict(k => v for (k, v) in demanda if !(k[1] in excl) && v >= LIMIAR_RHS)
CP_c    = sort(unique([(c, p) for (c, p, t) in keys(demanda_c)]))
CPset_c = Set(CP_c)
vol_prod(f, t) = get(volume_producao, (f, t), 0.0) * get(cen.fator_capacidade, f, 1.0)

# [M4] meses com demanda por (cliente, produto) e pares cujo preço varia no horizonte (coortes)
tds_cp = Dict{Tuple{String,Int},Vector{Int}}()
for (c, p, t) in keys(demanda_c)
    push!(get!(tds_cp, (c, p), Int[]), t)
end
for v in values(tds_cp)
    sort!(v)
end
pares_coorte = Set{Tuple{String,Int}}()
if PRECO_POR_COORTE
    for ((c, p), tds) in tds_cp
        precos = [get(preco_venda, (c, p, td), 0.0) for td in tds]
        if maximum(precos) - minimum(precos) > 1e-9 * max(1.0, maximum(precos))
            push!(pares_coorte, (c, p))
        end
    end
end

# Produtos disponíveis em cada POL (produção a montante ou estoque inicial)
disp_pol = Dict(pol => Set{Int}() for pol in POL)
for pol in POL, p in P
    get(estoque_inicial, (pol, p), 0.0) > 0 && push!(disp_pol[pol], p)
end
for (f, p) in FP
    pol = get(FabricaPOL, f, "")
    haskey(disp_pol, pol) && push!(disp_pol[pol], p)
end

# Produtos demandados em cada POD (por algum cliente atendido por ele)
dem_pod = Dict(pod => Set{Int}() for pod in POD)
for pod in POD, c in clientes_do_pod[pod], p in P
    (c, p) in CPset_c && push!(dem_pod[pod], p)
end

# Produtos que podem fluir de um POL para um POD
prod_par = Dict{Tuple{String,String},Vector{Int}}()
function produtos_do_par(pol, pod)
    return get!(prod_par, (pol, pod)) do
        sort!(collect(intersect(disp_pol[pol], dem_pod[pod])))
    end
end

# Segmentos (origem k -> destino j) viáveis de cada rota
seg_rota = Vector{Vector{Tuple{Int,Int}}}(undef, length(rotas))
for r in rotas
    lista = Tuple{Int,Int}[]
    for j in eachindex(r.destinos), k in eachindex(r.origens)
        isempty(produtos_do_par(r.origens[k], r.destinos[j])) || push!(lista, (k, j))
    end
    seg_rota[r.id] = lista
end

# (rota, t) -> segmentos cuja chegada cai dentro do horizonte
segmentos = Dict{Tuple{Int,Int},Vector{Tuple{Int,Int}}}()
for r in rotas, t in T
    lista = [(k, j) for (k, j) in seg_rota[r.id] if (t + r.lag_desc[j]) in Tset]
    isempty(lista) || (segmentos[(r.id, t)] = lista)
end

# Trechos distintos (POL, POD, tempo de viagem)
trecho_set = Set{Tuple{String,String,Int}}()
for r in rotas, (k, j) in seg_rota[r.id]
    push!(trecho_set, (r.origens[k], r.destinos[j], r.lag_desc[j]))
end
trechos = sort(collect(trecho_set))
tid = Dict(tr => i for (i, tr) in enumerate(trechos))

# ---------------- Diagnóstico de tamanho ----------------
n_y      = sum(length(l) for l in values(segmentos); init = 0)
n_navios = length(segmentos)
n_x = sum(length(produtos_do_par(pol, pod))
          for (pol, pod, lag) in trechos for t in T if (t + lag) in Tset; init = 0)
n_vendas = nT * sum(1 for (c, pod) in ClientePODs for p in P if (c, p) in CPset_c; init = 0)
n_denso  = (length(L) + length(POL) + 2 * length(POD)) * nP * nT
n_outros = 2 * length(FP) * nT + length(CP_c) * (nT + 1)
n_coorte = 0
for cp in pares_coorte, td in tds_cp[cp]
    n_coorte += count(t -> t >= td, T)
end
n_total  = n_y + 6 * n_navios + n_x + n_vendas + n_denso + n_outros + n_coorte

MODO_TESTE && println("*** MODO TESTE ATIVO: dados filtrados; resultado NÃO representa o problema completo ***")
println("Cenário: ", cen.nome, " | dias SS: ", cen.dias_ss, " | recusa livre: ", cen.recusar_livre)
println("Rotas: ", length(rotas), " | Produtos: ", nP, " | Instantes: ", nT)
println("Trechos (POL,POD,tempo): ", length(trechos))
println("Rotas x instantes com viagem possível: ", n_navios)
println("Variáveis y (volume por segmento): ", n_y)
println("Variáveis x (produto por trecho):  ", n_x)
println("Variáveis de venda:                ", n_vendas)
println("Variáveis de coorte de preço:      ", n_coorte, " (pares: ", length(pares_coorte), ")")
println("Variáveis de estoque/porto:        ", n_denso)
println("TOTAL estimado de variáveis:       ", n_total)
println("Memória total (GB): ", round(Sys.total_memory() / 2^30, digits = 1),
        " | livre (GB): ", round(Sys.free_memory() / 2^30, digits = 1))
flush(stdout)

if n_total > MAX_VARIAVEIS
    error("Modelo estimado em $n_total variáveis (> MAX_VARIAVEIS = $MAX_VARIAVEIS). " *
          "Abortado para não travar o computador. Aumente MAX_VARIAVEIS ou reduza o modelo.")
end
isempty(segmentos) && error("Nenhuma rota viável: verifique produção nos POLs e demanda nos PODs")

# ---------------- Solver ----------------
model = direct_model(HiGHS.Optimizer())
set_string_names_on_creation(model, false)
set_optimizer_attribute(model, "time_limit", tempo_limite)
if relaxar
    set_optimizer_attribute(model, "solver", SOLVER_RELAXACAO)
    SOLVER_RELAXACAO == "ipm" && set_optimizer_attribute(model, "run_crossover", IPM_CROSSOVER ? "on" : "off")
else
    set_optimizer_attribute(model, "mip_rel_gap", GAP_MIP)
    set_optimizer_attribute(model, "mip_heuristic_effort", MIP_ESFORCO_HEURISTICO)
end

function nova_var(nome; lb = 0.0, ub = Inf, tipo = :cont)
    v = @variable(model)
    if tipo == :bin && !relaxar
        set_binary(v)
    else
        if tipo == :bin
            lb = 0.0; ub = 1.0
        end
        isfinite(lb) && set_lower_bound(v, lb)
        isfinite(ub) && set_upper_bound(v, ub)
        tipo == :int && !relaxar && set_integer(v)
    end
    return v
end

# ---------------- Variáveis densas ----------------
@variable(model, estoque[loc in L, p in P, t in T] >= 0)
@variable(model, load[pol in POL, p in P, t in T] >= 0)
@variable(model, unload[pod in POD, p in P, t in T] >= 0)
@variable(model, folga_ss[pod in POD, p in P, t in T] >= 0)

# ---------------- Variáveis esparsas ----------------
producao = Dict{Tuple{String,Int,Int},VariableRef}()
fab_pol  = Dict{Tuple{String,Int,Int},VariableRef}()
for (f, p) in FP, t in T
    producao[(f, p, t)] = nova_var("producao")
    fab_pol[(f, p, t)]  = nova_var("fab_pol")
end

vendas = Dict{Tuple{String,String,Int,Int},VariableRef}()
for (c, pod) in ClientePODs, p in P, t in T
    (c, p) in CPset_c || continue
    vendas[(c, pod, p, t)] = nova_var("vendas")
end

# [M4] atend[c,p,td,t]: demanda do mês td atendida no mês t (só onde o preço varia)
atend = Dict{Tuple{String,Int,Int,Int},VariableRef}()
for (c, p) in pares_coorte, td in tds_cp[(c, p)], t in T
    t >= td && (atend[(c, p, td, t)] = nova_var("atend"))
end

backlog = Dict{Tuple{String,Int,Int},VariableRef}()
spot    = Dict{Tuple{String,Int},VariableRef}()
for (c, p) in CP_c
    for t in T
        backlog[(c, p, t)] = nova_var("backlog")
    end
    spot[(c, p)] = nova_var("spot")
end

navios  = Dict{Tuple{Int,Int},VariableRef}()
faixa   = Dict{Tuple{Int,Int,Int},VariableRef}()
z_faixa = Dict{Tuple{Int,Int,Int},VariableRef}()
y       = Dict{Tuple{Int,Int,Int,Int},VariableRef}()
for ((rid, t), lista) in segmentos
    navios[(rid, t)] = nova_var("navios"; ub = frota_teto[rotas[rid].armador], tipo = :int)
    for k in 1:K
        faixa[(rid, t, k)] = nova_var("faixa")
        k >= 2 && (z_faixa[(rid, t, k)] = nova_var("z_faixa"; tipo = :bin))
    end
    for (k, j) in lista
        y[(rid, k, j, t)] = nova_var("y")
    end
end

xf = Dict{Tuple{Int,Int,Int},VariableRef}()
for (i, (pol, pod, lag)) in enumerate(trechos)
    ps = produtos_do_par(pol, pod)
    for t in T
        (t + lag) in Tset || continue
        for p in ps
            xf[(i, p, t)] = nova_var("x")
        end
    end
end

# ---------------- Expressões de custo/receita ----------------
receita     = AffExpr(0.0)
frete       = AffExpr(0.0)
inland      = AffExpr(0.0)
holding     = AffExpr(0.0)
pen_backlog = AffExpr(0.0)
pen_ss      = AffExpr(0.0)
pen_spot    = AffExpr(0.0)
pen_bal     = AffExpr(0.0)
residual    = AffExpr(0.0)
pen_flex    = AffExpr(0.0)

# [FLEX] folgas penalizadas: folgas[tipo][chave] = variável
folgas = Dict{Symbol,Dict{Any,VariableRef}}()
PEN_FROTA = PCT_PEN_FROTA * preco_medio * (isempty(rotas) ? 1.0 : mean(r.max_in for r in rotas))
function folga(tipo::Symbol, chave, pen)
    FLEXIBILIZAR || return 0.0
    v = nova_var(string(tipo))
    get!(() -> Dict{Any,VariableRef}(), folgas, tipo)[chave] = v
    add_to_expression!(pen_flex, pen, v)
    return v
end

pen_bl = cen.recusar_livre ? 0.0 : PEN_BACKLOG
pen_sp = cen.recusar_livre ? 0.0 : PEN_SPOT

for ((c, pod, p, t), v) in vendas
    (c, p) in pares_coorte || add_to_expression!(receita, preco_mes(c, p, t), v)
    add_to_expression!(inland, custo_inland[(c, pod)], v)
end
for ((c, p, td, t), v) in atend
    add_to_expression!(receita, get(preco_venda, (c, p, td), 0.0), v)   # preço do mês da DEMANDA
end
for ((rid, t, k), v) in faixa
    desconto = FAIXAS_FRETE[k][3]
    add_to_expression!(frete, rotas[rid].frete * (1 - desconto), v)
end
for loc in L, p in P, t in T
    custo_estoque[loc] == 0 && continue
    add_to_expression!(holding, custo_estoque[loc], estoque[loc, p, t])
end
for ((c, p, t), v) in backlog
    t < tN && pen_bl > 0 && add_to_expression!(pen_backlog, pen_bl, v)
end
for v in folga_ss
    add_to_expression!(pen_ss, PEN_SS, v)
end
for (_, v) in spot
    pen_sp > 0 && add_to_expression!(pen_spot, pen_sp, v)
end
if VALOR_RESIDUAL_PCT > 0
    for pod in POD, p in P
        add_to_expression!(residual, VALOR_RESIDUAL_PCT * preco_medio, estoque[pod, p, tN])
    end
end

# =====================================================================
# RESTRIÇÕES
# =====================================================================
estoque_ant(loc, p, t) = t == t0 ? limpa(get(estoque_inicial, (loc, p), 0.0)) : estoque[loc, p, t-1]

# ---------- Balanço de estoque na fábrica ----------
for f in F, p in P, t in T
    prod_ft  = (f, p) in FPset ? producao[(f, p, t)] : 0.0
    envio_ft = (f, p) in FPset ? fab_pol[(f, p, t)]  : 0.0
    @constraint(model, estoque[f, p, t] == estoque_ant(f, p, t) + prod_ft - envio_ft)
    # [M1] se o envio fábrica->POL for instantâneo, estoque >= 0 já limita o envio ao disponível
    (!FABRICA_POL_MESMO_MES && (f, p) in FPset) &&
        @constraint(model, fab_pol[(f, p, t)] <= estoque_ant(f, p, t))
end

# ---------- Capacidade da fábrica (100% utilizada) ----------
for f in F, t in T
    vol = vol_prod(f, t)
    linhas = [producao[(f, p, t)] for p in P if (f, p) in FPset]
    if isempty(linhas)
        vol > 0 && @warn "Fábrica $f tem VOLUME_PRODUCAO > 0 em t=$t mas não produz nenhuma linha ativa"
        continue
    end
    if MODO_TESTE && TESTE_MAX_PRODUTOS > 0
        @constraint(model, sum(linhas) <= vol)
    else
        # [FLEX] produção == volume, mas com ociosidade penalizada (fábrica pode produzir menos se não houver escoamento)
        @constraint(model, sum(linhas) + folga(:prod_ociosa, (f, t), PEN_PROD_OCIOSA) == limpa(vol))
    end
end

# ---------- Balanço de estoque no POL ----------
for pol in POL, p in P, t in T
    entradas = [fab_pol[(f, p, t)] for f in F if get(FabricaPOL, f, "") == pol && (f, p) in FPset]
    @constraint(model, estoque[pol, p, t] ==
        estoque_ant(pol, p, t) + sum(entradas; init = 0.0) - load[pol, p, t])
    # [M1] só limita ao estoque anterior se o envio fábrica->POL não for instantâneo
    !FABRICA_POL_MESMO_MES && @constraint(model, load[pol, p, t] <= estoque_ant(pol, p, t))
end

# ---------- Balanço de estoque no POD ----------
for pod in POD, p in P, t in T
    saidas = [vendas[(c, pod, p, t)] for c in clientes_do_pod[pod] if (c, p) in CPset_c]
    @constraint(model, estoque[pod, p, t] ==
        estoque_ant(pod, p, t) + unload[pod, p, t] - sum(saidas; init = 0.0))
end

# ---------- Conservação de demanda com backlog e spot ----------
for (c, p) in CP_c, t in T
    vend = [vendas[(c, pod, p, t)] for pod in pods_do_cliente[c]]
    ant  = t == t0 ? 0.0 : backlog[(c, p, t-1)]
    @constraint(model, backlog[(c, p, t)] == ant + get(demanda_c, (c, p, t), 0.0) - sum(vend; init = 0.0))
end
for (c, p) in CP_c
    @constraint(model, spot[(c, p)] == backlog[(c, p, tN)])
end

# ---------- [M4] Coortes de preço: cada venda é ligada ao mês da demanda que atende ----------
for (c, p) in pares_coorte
    tds = tds_cp[(c, p)]
    for t in T
        alvo = [atend[(c, p, td, t)] for td in tds if td <= t]
        isempty(alvo) && continue
        vend = [vendas[(c, pod, p, t)] for pod in pods_do_cliente[c]]
        @constraint(model, sum(vend; init = 0.0) == sum(alvo; init = 0.0))
    end
    for td in tds
        dem_td = [atend[(c, p, td, t)] for t in T if t >= td]
        @constraint(model, sum(dem_td; init = 0.0) <= demanda_c[(c, p, td)])
    end
end

# ---------- [M7] Estoque de segurança nos PODs ----------
# Demanda planejada com divisão igual entre os PODs do cliente (usada no balanceamento
# e na base :demanda_igual). Cobertura ao final de t é medida contra o mês t+1.
function demanda_pod(pod, p, t)
    tt = t < tN ? t + 1 : t
    total = 0.0
    for c in clientes_do_pod[pod]
        total += get(demanda_c, (c, p, tt), 0.0) / length(pods_do_cliente[c])
    end
    return total
end

if cobertura > 0
    for pod in POD, p in P, t in T
        if BASE_ESTOQUE_SEGURANCA == :vendas
            tt = t < tN ? t + 1 : t
            vn = [vendas[(c, pod, p, tt)] for c in clientes_do_pod[pod] if (c, p) in CPset_c]
            isempty(vn) && continue
            @constraint(model, estoque[pod, p, t] + folga_ss[pod, p, t] >= cobertura * sum(vn; init = 0.0))
        else
            req = cobertura * demanda_pod(pod, p, t)
            req > 1e-3 / ESCALA_TON || continue
            @constraint(model, estoque[pod, p, t] + folga_ss[pod, p, t] >= req)
        end
    end
end

# ---------- [M7] Balanceamento de cobertura entre PODs (penalidade suave) ----------
if PEN_BALANCEAMENTO > 0
    lim = BAL_DEMANDA_MIN_TON / ESCALA_TON
    for p in P, t in T
        pods_b = [pod for pod in POD if demanda_pod(pod, p, t) >= lim]
        length(pods_b) >= 2 || continue
        reqs = [demanda_pod(pod, p, t) for pod in pods_b]
        cmax = nova_var("cmax")
        cmin = nova_var("cmin")
        for (pod, rq) in zip(pods_b, reqs)
            @constraint(model, cmax >= estoque[pod, p, t] / rq)
            @constraint(model, cmin <= estoque[pod, p, t] / rq)
        end
        add_to_expression!(pen_bal,  PEN_BALANCEAMENTO * mean(reqs), cmax)
        add_to_expression!(pen_bal, -PEN_BALANCEAMENTO * mean(reqs), cmin)
    end
end

# ---------- Capacidade máxima de estoque (fim do mês) ----------
for loc in L, t in T
    haskey(max_estoque, loc) || continue
    @constraint(model, sum(estoque[loc, p, t] for p in P) <= max_estoque[loc] + folga(:cap_estoque, (loc, t), PEN_CAP_ESTOQUE))
end

# ---------- [M3] Capacidade no PICO: estoque anterior + entrada do mês ----------
if RESTRINGIR_PICO_ESTOQUE
    for pod in POD, t in T
        haskey(max_estoque, pod) || continue
        e = AffExpr(0.0)
        for p in P
            a = estoque_ant(pod, p, t)
            a isa Number ? (e.constant += a) : add_to_expression!(e, 1.0, a)
            add_to_expression!(e, 1.0, unload[pod, p, t])
        end
        @constraint(model, e <= max_estoque[pod] + folga(:cap_pico, (pod, t), PEN_CAP_ESTOQUE))
    end
    for pol in POL, t in T
        haskey(max_estoque, pol) || continue
        e = AffExpr(0.0)
        for p in P
            a = estoque_ant(pol, p, t)
            a isa Number ? (e.constant += a) : add_to_expression!(e, 1.0, a)
            for f in F
                (get(FabricaPOL, f, "") == pol && (f, p) in FPset) &&
                    add_to_expression!(e, 1.0, fab_pol[(f, p, t)])
            end
        end
        @constraint(model, e <= max_estoque[pol] + folga(:cap_pico, (pol, t), PEN_CAP_ESTOQUE))
    end
end

# ---------- [M3] Capacidades de envio (POL) e recebimento (POD) por mês ----------
for pol in POL, t in T
    haskey(cap_envio, pol) || continue
    @constraint(model, sum(load[pol, p, t] for p in P) <= cap_envio[pol] + folga(:cap_envio, (pol, t), PEN_CAP_PORTO))
end
for pod in POD, t in T
    haskey(cap_receb, pod) || continue
    @constraint(model, sum(unload[pod, p, t] for p in P) <= cap_receb[pod] + folga(:cap_receb, (pod, t), PEN_CAP_PORTO))
end

# ---------- Restrições por rota e instante de partida ----------
for ((rid, t), lista) in segmentos
    r     = rotas[rid]
    nav   = navios[(rid, t)]
    total = sum(y[(rid, k, j, t)] for (k, j) in lista)
    teto  = frota_teto[r.armador]

    # Min / Max intake
    @constraint(model, total >= r.min_in * nav)
    @constraint(model, total <= r.max_in * nav)

    # Calado nos POLs, respeitando a ordem de carregamento
    for k in eachindex(r.origens)
        o = r.origens[k]
        haskey(caladoDWT, o) || continue
        ate_k = [(kk, j) for (kk, j) in lista if kk <= k]
        isempty(ate_k) && continue
        @constraint(model, sum(y[(rid, kk, j, t)] for (kk, j) in ate_k) <= caladoDWT[o] * nav)
    end

    # [M2] Calado nos PODs
    if CALADO_DESCARGA_POR_PARADA
        for j in eachindex(r.destinos)
            d = r.destinos[j]
            haskey(caladoDWT, d) || continue
            restante = [(k, jj) for (k, jj) in lista if jj >= j]
            isempty(restante) && continue
            @constraint(model, sum(y[(rid, k, jj, t)] for (k, jj) in restante) <= caladoDWT[d] * nav)
        end
    else
        cal = [caladoDWT[d] for d in r.destinos if haskey(caladoDWT, d)]
        isempty(cal) || @constraint(model, total <= maximum(cal) * nav)
    end

    # ---------- Frete escalonado ----------
    # [M6] Premissa: navios de uma (rota, mês) com carga igual. Ocupação = carga / (MAX_INTAKE * navios).
    # big-M usa o teto REAL de frota do armador (mais apertado que uma constante global).
    cap = r.max_in * nav
    @constraint(model, sum(faixa[(rid, t, k)] for k in 1:K) == total)
    for k in 1:K
        lo, hi, _ = FAIXAS_FRETE[k]
        @constraint(model, faixa[(rid, t, k)] <= (hi - lo) * cap)
        if k >= 2
            lo_a, hi_a, _ = FAIXAS_FRETE[k-1]
            M_k = (hi - lo)     * r.max_in * teto
            M_a = (hi_a - lo_a) * r.max_in * teto
            z = z_faixa[(rid, t, k)]
            @constraint(model, faixa[(rid, t, k)] <= M_k * z)
            @constraint(model, faixa[(rid, t, k-1)] >= (hi_a - lo_a) * cap - M_a * (1 - z))
            k >= 3 && @constraint(model, z <= z_faixa[(rid, t, k-1)])
        end
    end
end

# ---------- Ligação rota <-> trecho ----------
acum_trecho = Dict{Tuple{Int,Int},AffExpr}()
for ((rid, t), lista) in segmentos
    r = rotas[rid]
    for (k, j) in lista
        i = tid[(r.origens[k], r.destinos[j], r.lag_desc[j])]
        e = get!(() -> AffExpr(0.0), acum_trecho, (i, t))
        add_to_expression!(e, 1.0, y[(rid, k, j, t)])
    end
end
for (i, (pol, pod, lag)) in enumerate(trechos), t in T
    (t + lag) in Tset || continue
    ps = produtos_do_par(pol, pod)
    @constraint(model, sum(xf[(i, p, t)] for p in ps) == get(acum_trecho, (i, t), AffExpr(0.0)))
end

# ---------- Ligação trecho <-> estoques dos portos ----------
carga_pol    = Dict{Tuple{String,Int,Int},AffExpr}()
descarga_pod = Dict{Tuple{String,Int,Int},AffExpr}()
for ((i, p, t), v) in xf
    pol, pod, lag = trechos[i]
    add_to_expression!(get!(() -> AffExpr(0.0), carga_pol,    (pol, p, t)),       1.0, v)
    add_to_expression!(get!(() -> AffExpr(0.0), descarga_pod, (pod, p, t + lag)), 1.0, v)
end
for pol in POL, p in P, t in T
    @constraint(model, load[pol, p, t] == get(carga_pol, (pol, p, t), AffExpr(0.0)))
end
# [M9] unload = chegadas das viagens do horizonte + trânsito inicial
for pod in POD, p in P, ta in T
    @constraint(model, unload[pod, p, ta] ==
        get(descarga_pod, (pod, p, ta), AffExpr(0.0)) + limpa(get(transito_inicial, (pod, p, ta), 0.0)))
end

# ---------- Frota: disponibilidade dos navios (por armador e por mês) ----------
ocupacao = Dict{Tuple{String,Int},AffExpr}()
for ((rid, ts), v) in navios
    r = rotas[rid]
    for t in ts:min(tN, ts + r.ciclo - 1)
        t in Tset || continue
        add_to_expression!(get!(() -> AffExpr(0.0), ocupacao, (r.armador, t)), 1.0, v)
    end
end
for ((a, t), e) in ocupacao
    @constraint(model, e <= frota_max(a, t) + folga(:frota, (a, t), PEN_FROTA))
end

# ---------- Objetivo ----------
@objective(model, Max, receita + residual - frete - inland - holding - pen_backlog - pen_ss - pen_spot - pen_bal - pen_flex)

return (model = model, estoque = estoque, load = load, unload = unload, folga_ss = folga_ss,
        producao = producao, fab_pol = fab_pol, vendas = vendas, backlog = backlog, spot = spot,
        navios = navios, faixa = faixa, y = y, xf = xf, segmentos = segmentos, trechos = trechos, folgas = folgas,
        tid = tid, atend = atend, pares_coorte = pares_coorte, demanda_c = demanda_c,
        expr = (receita = receita, residual = residual, frete = frete, inland = inland,
                holding = holding, pen_backlog = pen_backlog, pen_ss = pen_ss,
                pen_spot = pen_spot, pen_bal = pen_bal, pen_flex = pen_flex))
end   # construir_modelo


# =====================================================================
# EXTRAÇÃO DE RESULTADOS (tabelas em toneladas e moeda originais)
# =====================================================================
# [FLEX] Relatório das folgas usadas. Frota em navios-mês; demais em toneladas.
function folgas_usadas(res; limiar = 1e-6)
    df = DataFrame(TIPO = String[], CHAVE = String[], VALOR = Float64[], UNIDADE = String[])
    for (tipo, d) in res.folgas, (k, v) in d
        x = value(v)
        x > limiar || continue
        esc = tipo == :frota ? 1.0 : ESCALA_TON
        push!(df, (String(tipo), string(k), esc * x, tipo == :frota ? "navio-mes" : "ton"))
    end
    sort!(df, [:TIPO, order(:VALOR, rev = true)])
    return df
end

function imprimir_folgas(res)
    df = folgas_usadas(res)
    if nrow(df) == 0
        println("Restrições flexíveis: nenhuma folga usada (o modelo original já era factível).")
        return df
    end
    println("Restrições flexíveis: folgas USADAS (restrições que estavam impossíveis / apertadas):")
    for g in groupby(df, :TIPO)
        println("  - ", g.TIPO[1], ": ", nrow(g), " ocorrências | total = ", round(sum(g.VALOR), digits = 2), " ", g.UNIDADE[1],
                " | maior: ", g.CHAVE[1], " = ", round(g.VALOR[1], digits = 2))
    end
    flush(stdout)
    return df
end

resumo_vazio(nome, status) = (cenario = nome, status = status,
    lucro_objetivo = NaN, lucro_operacional = NaN, receita = NaN, frete = NaN, inland = NaN,
    estoque_custo = NaN, penalidades = NaN, spot_ton = NaN, violacao_ss_ton_mes = NaN, violacao_flex_ton = NaN,
    backlog_ton_mes = NaN, estoque_medio_pod_ton = NaN, viagens = NaN, gap_pct = NaN)

function extrair_resultado(res, cen, rotas_m, obj_rel, st1, n_usadas)
    model = res.model
    R = Dict{Symbol,Any}()
    R[:cenario]       = cen.nome
    R[:status]        = termination_status(model)
    R[:tem_solucao]   = has_values(model)
    R[:res]           = res
    R[:rotas_modelo]  = rotas_m
    R[:obj_relaxacao] = obj_rel
    R[:st_fase1]      = st1
    R[:n_rotas_usadas_fase1] = n_usadas
    R[:tabelas]       = Pair{String,DataFrame}[]
    R[:resumo]        = resumo_vazio(cen.nome, string(R[:status]))
    R[:tem_solucao] || return R

    K = length(FAIXAS_FRETE)
    lucro = ESCALA_MOEDA * objective_value(model)
    E = Dict{Symbol,Float64}()
    for (k, e) in pairs(res.expr)
        E[k] = ESCALA_MOEDA * value(e)
    end
    lucro_oper = E[:receita] + E[:residual] - E[:frete] - E[:inland] - E[:holding]
    pen_total  = E[:pen_backlog] + E[:pen_ss] + E[:pen_spot] + E[:pen_bal] + E[:pen_flex]
    df_folgas  = folgas_usadas(res)
    viol_flex  = sum(df_folgas.VALOR[df_folgas.UNIDADE .== "ton"]; init = 0.0)

    estoque_v  = value.(res.estoque)
    folga_v    = value.(res.folga_ss)

    spot_ton   = ESCALA_TON * sum(value(v) for (_, v) in res.spot; init = 0.0)
    viol_ss    = ESCALA_TON * sum(folga_v)
    backlog_t  = ESCALA_TON * sum(value(v) for ((c, p, t), v) in res.backlog if t < tN; init = 0.0)
    est_pod    = ESCALA_TON * sum(estoque_v[pod, p, t] for pod in POD, p in P, t in T; init = 0.0) / length(T)

    # ---------- Produção por fábrica ----------
    df_prod = DataFrame(FABRICA = String[], FAMILIA = String[], LINHA = String[], INSTANTE = Int[], TON = Float64[])
    for ((f, p, t), x) in res.producao
        q = ESCALA_TON * value(x)
        q > 1e-3 && push!(df_prod, (f, prod_id[p][1], prod_id[p][2], t, q))
    end
    sort!(df_prod, [:FABRICA, :INSTANTE, :FAMILIA, :LINHA])

    # ---------- Viagens por rota / segmentos ----------
    df_viag = DataFrame(ID_ROTA_CSV = Int[], ARMADOR = String[], ORIGENS = String[], DESTINOS = String[],
        INSTANTE_PARTIDA = Int[], NAVIOS = Float64[], TON = Float64[], OCUPACAO_PCT = Float64[],
        FRETE_TOTAL = Float64[], FRETE_MEDIO_TON = Float64[], GREENFIELD = Bool[])
    df_seg = DataFrame(ID_ROTA_CSV = Int[], ARMADOR = String[], POL = String[], POD = String[],
        INSTANTE_PARTIDA = Int[], INSTANTE_CHEGADA = Int[], TON = Float64[])
    custo_viagem = Dict{Tuple{Int,Int},Float64}()   # moeda
    tot_viagem   = Dict{Tuple{Int,Int},Float64}()   # unidades escaladas de ton
    for ((rid, t), nv) in res.navios
        nvv = value(nv)
        nvv > 1e-4 || continue
        r = rotas_m[rid]
        lista = res.segmentos[(rid, t)]
        tot = sum(value(res.y[(rid, k, j, t)]) for (k, j) in lista)
        custo = ESCALA_MOEDA * sum(r.frete * (1 - FAIXAS_FRETE[k][3]) * value(res.faixa[(rid, t, k)]) for k in 1:K)
        custo_viagem[(rid, t)] = custo
        tot_viagem[(rid, t)]   = tot
        ocup = r.max_in > 0 ? 100 * tot / (r.max_in * nvv) : NaN
        push!(df_viag, (r.id_orig, r.armador, join(r.origens, ";"), join(r.destinos, ";"), t, nvv,
                        ESCALA_TON * tot, ocup, custo, tot > 0 ? custo / (ESCALA_TON * tot) : 0.0, r.id_orig < 0))
        for (k, j) in lista
            q = ESCALA_TON * value(res.y[(rid, k, j, t)])
            q > 1e-3 && push!(df_seg, (r.id_orig, r.armador, r.origens[k], r.destinos[j], t, t + r.lag_desc[j], q))
        end
    end
    sort!(df_viag, [:INSTANTE_PARTIDA, :ARMADOR])
    sort!(df_seg, [:INSTANTE_PARTIDA, :ID_ROTA_CSV])

    # ---------- Fluxo de produto por trecho ----------
    df_fluxo = DataFrame(POL = String[], POD = String[], INSTANTE_PARTIDA = Int[], INSTANTE_CHEGADA = Int[],
        FAMILIA = String[], LINHA = String[], TON = Float64[])
    custo_trecho = Dict{Tuple{Int,Int},Float64}()
    ton_trecho   = Dict{Tuple{Int,Int},Float64}()
    for ((rid, t), lista) in res.segmentos
        haskey(custo_viagem, (rid, t)) || continue
        tot = tot_viagem[(rid, t)]
        tot > 1e-9 || continue
        cpt = custo_viagem[(rid, t)] / tot          # moeda por unidade escalada de ton
        r = rotas_m[rid]
        for (k, j) in lista
            yv = value(res.y[(rid, k, j, t)])
            i = res.tid[(r.origens[k], r.destinos[j], r.lag_desc[j])]
            custo_trecho[(i, t)] = get(custo_trecho, (i, t), 0.0) + yv * cpt
            ton_trecho[(i, t)]   = get(ton_trecho, (i, t), 0.0) + yv
        end
    end
    frete_pod_prod_custo = Dict{Tuple{String,Int},Float64}()
    frete_pod_prod_ton   = Dict{Tuple{String,Int},Float64}()
    for ((i, p, t), x) in res.xf
        q = value(x)
        q > 1e-9 || continue
        pol, pod, lag = res.trechos[i]
        push!(df_fluxo, (pol, pod, t, t + lag, prod_id[p][1], prod_id[p][2], ESCALA_TON * q))
        if get(ton_trecho, (i, t), 0.0) > 1e-9
            cm = custo_trecho[(i, t)] / ton_trecho[(i, t)]
            frete_pod_prod_custo[(pod, p)] = get(frete_pod_prod_custo, (pod, p), 0.0) + q * cm
            frete_pod_prod_ton[(pod, p)]   = get(frete_pod_prod_ton, (pod, p), 0.0) + q
        end
    end
    sort!(df_fluxo, [:INSTANTE_PARTIDA, :POL, :POD])

    # ---------- Estoques ----------
    df_est = DataFrame(LOCAL = String[], TIPO = String[], FAMILIA = String[], LINHA = String[],
        INSTANTE = Int[], TON = Float64[])
    for loc in L, p in P, t in T
        q = ESCALA_TON * estoque_v[loc, p, t]
        q > 1e-3 && push!(df_est, (loc, tipo_local[loc], prod_id[p][1], prod_id[p][2], t, q))
    end

    # ---------- Atendimento (cliente, POD, produto, mês) ----------
    rec_coorte = Dict{Tuple{String,Int,Int},Float64}()
    ton_coorte = Dict{Tuple{String,Int,Int},Float64}()
    for ((c, p, td, t), v) in res.atend
        q = value(v)
        q > 0 || continue
        rec_coorte[(c, p, t)] = get(rec_coorte, (c, p, t), 0.0) + q * get(preco_venda, (c, p, td), 0.0)
        ton_coorte[(c, p, t)] = get(ton_coorte, (c, p, t), 0.0) + q
    end
    function preco_efetivo(c, p, t)
        if (c, p) in res.pares_coorte
            tc = get(ton_coorte, (c, p, t), 0.0)
            return tc > 1e-12 ? rec_coorte[(c, p, t)] / tc : 0.0
        end
        return preco_mes(c, p, t)
    end
    df_atend = DataFrame(CLIENTE = String[], POD = String[], FAMILIA = String[], LINHA = String[],
        INSTANTE = Int[], TON = Float64[], PRECO_TON = Float64[], RECEITA = Float64[], CUSTO_INLAND = Float64[])
    rec_cli = Dict{String,Float64}(); inl_cli = Dict{String,Float64}(); fre_cli = Dict{String,Float64}()
    ton_cli = Dict{String,Float64}()
    cli_pod = Dict{Tuple{String,String},Float64}()
    for ((c, pod, p, t), v) in res.vendas
        q = value(v)
        q > 1e-9 || continue
        pe = preco_efetivo(c, p, t)
        rec = pe * q * ESCALA_MOEDA
        inl = custo_inland[(c, pod)] * q * ESCALA_MOEDA
        avg = get(frete_pod_prod_ton, (pod, p), 0.0) > 1e-9 ?
              frete_pod_prod_custo[(pod, p)] / frete_pod_prod_ton[(pod, p)] : 0.0
        fre = avg * q
        push!(df_atend, (c, pod, prod_id[p][1], prod_id[p][2], t, ESCALA_TON * q,
                         pe * ESCALA_MOEDA / ESCALA_TON, rec, inl))
        rec_cli[c] = get(rec_cli, c, 0.0) + rec
        inl_cli[c] = get(inl_cli, c, 0.0) + inl
        fre_cli[c] = get(fre_cli, c, 0.0) + fre
        ton_cli[c] = get(ton_cli, c, 0.0) + ESCALA_TON * q
        cli_pod[(c, pod)] = get(cli_pod, (c, pod), 0.0) + ESCALA_TON * q
    end
    sort!(df_atend, [:CLIENTE, :INSTANTE, :POD])

    # Por qual porto cada cliente é atendido
    df_cli_pod = DataFrame(CLIENTE = String[], POD = String[], TON = Float64[], PCT_DO_CLIENTE = Float64[])
    for ((c, pod), q) in cli_pod
        push!(df_cli_pod, (c, pod, q, 100 * q / ton_cli[c]))
    end
    sort!(df_cli_pod, [:CLIENTE, order(:TON, rev = true)])

    # ---------- Rentabilidade por cliente (frete alocado = frete médio do (POD, produto)) ----------
    dem_cli_tot = Dict{String,Float64}()
    for ((c, p, t), d) in res.demanda_c
        dem_cli_tot[c] = get(dem_cli_tot, c, 0.0) + ESCALA_TON * d
    end
    df_rent = DataFrame(CLIENTE = String[], DEMANDA_TON = Float64[], ATENDIDO_TON = Float64[], ATENDIDO_PCT = Float64[],
        RECEITA = Float64[], CUSTO_INLAND = Float64[], FRETE_ALOCADO = Float64[], MARGEM = Float64[],
        MARGEM_POR_TON = Float64[], PREJUIZO = Bool[])
    for c in sort(collect(keys(dem_cli_tot)))
        d   = dem_cli_tot[c]
        tn  = get(ton_cli, c, 0.0)
        rec = get(rec_cli, c, 0.0); inl = get(inl_cli, c, 0.0); fre = get(fre_cli, c, 0.0)
        marg = rec - inl - fre
        push!(df_rent, (c, d, tn, d > 0 ? 100 * tn / d : 0.0, rec, inl, fre, marg,
                        tn > 0 ? marg / tn : 0.0, tn > 0 && marg < 0))
    end
    tot_ton = sum(df_rent.ATENDIDO_TON); tot_rec = sum(df_rent.RECEITA)
    df_rent.PARTICIPACAO_VOLUME_PCT  = tot_ton > 0 ? 100 .* df_rent.ATENDIDO_TON ./ tot_ton : zeros(nrow(df_rent))
    df_rent.PARTICIPACAO_RECEITA_PCT = tot_rec > 0 ? 100 .* df_rent.RECEITA ./ tot_rec : zeros(nrow(df_rent))
    sort!(df_rent, :MARGEM)

    # ---------- Violações de estoque de segurança e backlog ----------
    df_viol = DataFrame(POD = String[], FAMILIA = String[], LINHA = String[], INSTANTE = Int[], TON = Float64[])
    for pod in POD, p in P, t in T
        q = ESCALA_TON * folga_v[pod, p, t]
        q > 1e-3 && push!(df_viol, (pod, prod_id[p][1], prod_id[p][2], t, q))
    end
    df_back = DataFrame(CLIENTE = String[], FAMILIA = String[], LINHA = String[], INSTANTE = Int[], TON = Float64[])
    for ((c, p, t), v) in res.backlog
        q = ESCALA_TON * value(v)
        q > 1e-3 && push!(df_back, (c, prod_id[p][1], prod_id[p][2], t, q))
    end

    # ---------- Resumo financeiro ----------
    gap = NaN
    if !(cen.nome == "__fase1__")
        try
            gap = 100 * relative_gap(model)
        catch
            gap = NaN
        end
    end
    df_fin = DataFrame(ITEM = ["Receita", "Valor residual estoque final", "Frete maritimo", "Custo inland",
                               "Custo de estoque", "LUCRO OPERACIONAL", "Penalidade backlog",
                               "Penalidade estoque de seguranca", "Penalidade spot / nao atendido",
                               "Penalidade balanceamento", "Penalidade restricoes flexiveis", "LUCRO (OBJETIVO)"],
                       VALOR = [E[:receita], E[:residual], -E[:frete], -E[:inland], -E[:holding], lucro_oper,
                                -E[:pen_backlog], -E[:pen_ss], -E[:pen_spot], -E[:pen_bal], -E[:pen_flex], lucro])

    push!(R[:tabelas], "producao_fabrica" => df_prod)
    push!(R[:tabelas], "viagens_por_rota" => df_viag)
    push!(R[:tabelas], "viagens_segmentos" => df_seg)
    push!(R[:tabelas], "fluxo_produto_por_trecho" => df_fluxo)
    push!(R[:tabelas], "estoque_por_local" => df_est)
    push!(R[:tabelas], "atendimento_cliente" => df_atend)
    push!(R[:tabelas], "cliente_por_porto" => df_cli_pod)
    push!(R[:tabelas], "rentabilidade_clientes" => df_rent)
    push!(R[:tabelas], "violacao_estoque_seguranca" => df_viol)
    push!(R[:tabelas], "backlog" => df_back)
    push!(R[:tabelas], "resumo_financeiro" => df_fin)
    push!(R[:tabelas], "folgas_restricoes_flexiveis" => df_folgas)

    R[:rentabilidade] = df_rent
    R[:resumo] = (cenario = cen.nome, status = string(R[:status]),
        lucro_objetivo = lucro, lucro_operacional = lucro_oper, receita = E[:receita],
        frete = E[:frete], inland = E[:inland], estoque_custo = E[:holding], penalidades = pen_total,
        spot_ton = spot_ton, violacao_ss_ton_mes = viol_ss, violacao_flex_ton = viol_flex, backlog_ton_mes = backlog_t,
        estoque_medio_pod_ton = est_pod, viagens = sum(df_viag.NAVIOS), gap_pct = gap)
    return R
end

function exportar_resultado(R)
    (get(R, :tem_solucao, false) && EXPORTAR_RESULTADOS) || return nothing
    nome = replace(String(R[:cenario]), r"[^A-Za-z0-9_\-]" => "_")
    dir = joinpath(DIR_SAIDA, nome)
    mkpath(dir)
    for (arq, df) in R[:tabelas]
        nrow(df) == 0 && continue
        CSV.write(joinpath(dir, arq * ".csv"), df; delim = ';', decimal = ',')
    end
    df_r = DataFrame([R[:resumo]])
    CSV.write(joinpath(dir, "resumo_cenario.csv"), df_r; delim = ';', decimal = ',')
    println("Resultados exportados em: ", dir)
    return nothing
end

function imprimir_resultado(R, cen)
    st = R[:status]
    println("Status: ", st)
    if st != OPTIMAL
        if st == TIME_LIMIT && R[:tem_solucao]
            @warn "Limite de tempo atingido: há solução viável, mas o gap pode ser maior que GAP_MIP (veja o gap abaixo)."
        else
            @warn "O solver NÃO terminou como OPTIMAL: os valores abaixo (se houver) não são confiáveis."
        end
    end
    R[:tem_solucao] || return nothing
    s = R[:resumo]
    isnan(s.gap_pct) || println("Gap relativo (fase exata): ", round(s.gap_pct, digits = 2), " %")
    println("Lucro OPERACIONAL (receita - frete - inland - estoque): ", s.lucro_operacional)
    println("Penalidades (proxies de política):                      ", s.penalidades)
    println("Lucro (função objetivo):                                ", s.lucro_objetivo)
    obj_rel = R[:obj_relaxacao]
    if isfinite(obj_rel)
        ub = ESCALA_MOEDA * obj_rel
        println("Limite superior (relaxação com ", PREFILTRO_K > 0 ? "as rotas após o pré-filtro" : "TODAS as rotas", "): ", ub)
        println("Distância certificada ao ótimo: ", round(100 * (ub - s.lucro_objetivo) / abs(ub), digits = 2), " %",
                R[:st_fase1] == OPTIMAL ? "" : "  (fase 1 não foi OPTIMAL: valor indicativo)",
                "  [inclui gap de integralidade, não só a seleção de rotas]")
    end
    println("Demanda entregue via spot (ton): ", s.spot_ton)
    println("Violação total de estoque de segurança (ton·mês): ", s.violacao_ss_ton_mes)
    println("Backlog carregado entre meses (ton·mês): ", s.backlog_ton_mes)
    imprimir_folgas(R[:res])
    df_rent = R[:rentabilidade]
    prej = df_rent[df_rent.PREJUIZO, :]
    if nrow(prej) > 0
        println("Clientes com margem negativa (frete alocado pela média do POD): ", nrow(prej),
                " | ", round(sum(prej.PARTICIPACAO_VOLUME_PCT), digits = 2), " % do volume | prejuízo total: ",
                round(sum(prej.MARGEM), digits = 0))
    else
        println("Nenhum cliente com margem negativa (frete alocado pela média do POD).")
    end
    return nothing
end


# =====================================================================
# RESOLVER UM CENÁRIO (estratégia em duas fases)
# =====================================================================
function resolver(cen::Cenario; universo = rotas_base, rotas_pre = nothing, exportar::Bool = true,
                  tempo_limite::Float64 = TEMPO_LIMITE_S, tempo_fase1::Float64 = TEMPO_LIMITE_FASE1_S)
    println("\n##################### CENÁRIO: ", cen.nome, " #####################")
    rotas_cen    = renumerar(vcat(universo, cen.rotas_extras))
    rotas_modelo = rotas_cen
    obj_rel      = NaN
    st1          = nothing
    n_usadas     = 0

    if rotas_pre !== nothing
        rotas_modelo = renumerar(rotas_pre)
        println("Rotas pré-selecionadas fornecidas: ", length(rotas_modelo), " (fase 1 dispensada)")
    elseif ESTRATEGIA == :duas_fases
        println("\n===== FASE 1: relaxação (LP) com ", length(rotas_cen), " rotas =====")
        flush(stdout)
        res1 = construir_modelo(rotas_cen, true, tempo_fase1, cen)
        optimize!(res1.model)
        st1 = termination_status(res1.model)
        println("Fase 1 - Status: ", st1)
        if !has_values(res1.model)
            if st1 in (INFEASIBLE, INFEASIBLE_OR_UNBOUNDED, DUAL_INFEASIBLE)
                error("Fase 1 INFACTÍVEL (não é falta de tempo). " *
                      (FLEXIBILIZAR ? "Mesmo com folgas o modelo é infactível: revise dados (unidades, sinais, produtos sem POL/POD)." :
                                      "Ative FLEXIBILIZAR = true para localizar as restrições impossíveis."))
            else
                error("Fase 1 sem solução (status $st1). Reduza o problema (MODO_TESTE) ou aumente TEMPO_LIMITE_FASE1_S.")
            end
        end
        imprimir_folgas(res1)
        st1 == OPTIMAL || @warn "Fase 1 não terminou como OPTIMAL: a seleção de rotas e o limite superior podem não ser confiáveis."
        obj_rel = objective_value(res1.model)
        println("Fase 1 - Lucro da relaxação (limite superior): ", ESCALA_MOEDA * obj_rel)

        uso = Dict{Int,Float64}()
        for ((rid, t), v) in res1.navios
            uso[rid] = max(get(uso, rid, 0.0), value(v))
        end
        usadas = Set(rid for (rid, u) in uso if u > LIMIAR_USO_ROTA)
        n_usadas = length(usadas)
        if INCLUIR_IRMAS
            chave = r -> (r.armador, sort(r.origens), sort(r.destinos))
            chaves = Set(chave(rotas_cen[rid]) for rid in usadas)
            for r in rotas_cen
                chave(r) in chaves && push!(usadas, r.id)
            end
        end
        isempty(usadas) && error("A fase 1 não usou nenhuma rota; verifique os dados.")
        println("Fase 1 - Rotas usadas: ", n_usadas, " | com irmãs: ", length(usadas), " (de ", length(rotas_cen), ")")
        rotas_modelo = renumerar(rotas_cen[sort(collect(usadas))])
        res1 = nothing
        GC.gc()
    end

    relaxar2 = (ESTRATEGIA == :duas_fases || rotas_pre !== nothing) ? false : RELAXAR_INTEIROS
    println("\n===== ", (ESTRATEGIA == :duas_fases || rotas_pre !== nothing) ? "FASE EXATA" : "RESOLUÇÃO",
            ": ", length(rotas_modelo), " rotas =====")
    flush(stdout)
    res = construir_modelo(rotas_modelo, relaxar2, tempo_limite, cen)
    optimize!(res.model)

    R = extrair_resultado(res, cen, rotas_modelo, obj_rel, st1, n_usadas)
    imprimir_resultado(R, cen)
    exportar && exportar_resultado(R)
    return R
end


# =====================================================================
# GREENFIELD: estimar tempo e frete de rotas NOVAS a partir das observadas
#   tempo(POL,POD)  ~ a[POL] + b[POD]           (mínimos quadrados, pseudo-inversa)
#   frete(armador)  ~ c0 + c1 * tempo           (OLS por armador; pooled se < 4 observações)
#   frete final     = estimado * (1 + MARGEM_GREENFIELD)   (prêmio de segurança)
# Só corredores (POL, POD) sem NENHUMA rota atual são candidatos; escolhe-se o armador mais barato.
# =====================================================================
function ajusta_frete(rs)
    n  = length(rs)
    ts = Float64[Float64(r.ida) for r in rs]
    n >= 4 && length(unique(ts)) >= 2 || return nothing
    fs = Float64[Float64(r.frete) for r in rs]
    Xa = hcat(ones(n), ts)
    b  = Xa \ fs
    resid = fs .- Xa * b
    s = sqrt(sum(abs2, resid) / max(1, n - 2))
    return (b0 = b[1], b1 = b[2], s = s, n = n)
end

function estimar_greenfield(rotas_ref)
    simples = [r for r in rotas_ref if length(r.origens) == 1 && length(r.destinos) == 1]
    if length(simples) < 5
        @warn "Greenfield: menos de 5 rotas simples observadas; impossível estimar tempos e fretes."
        return Any[], DataFrame()
    end
    pols = sort(unique([r.origens[1] for r in simples]))
    pods = sort(unique([r.destinos[1] for r in simples]))
    X  = zeros(length(simples), length(pols) + length(pods))
    yv = Float64[Float64(r.ida) for r in simples]
    for (i, r) in enumerate(simples)
        X[i, findfirst(==(r.origens[1]), pols)] = 1.0
        X[i, length(pols) + findfirst(==(r.destinos[1]), pods)] = 1.0
    end
    beta = pinv(X) * yv

    obs_any = Set((o, d) for r in rotas_ref for o in r.origens for d in r.destinos)
    piso    = 0.5 * minimum(Float64(r.frete) for r in simples)
    armadores = sort(unique([r.armador for r in simples]))
    modelo_pool = ajusta_frete(simples)
    modelos = Dict{String,Any}()
    for a in armadores
        m = ajusta_frete([r for r in simples if r.armador == a])
        modelos[a] = m === nothing ? modelo_pool : m
    end

    cands = Any[]
    for (ip, pol) in enumerate(pols), (ib, pod) in enumerate(pods)
        (pol, pod) in obs_any && continue
        isempty(clientes_do_pod[pod]) && continue
        ida = arred(max(0.0, beta[ip] + beta[length(pols) + ib]))
        melhor = nothing
        for a in armadores
            m = modelos[a]
            m === nothing && continue
            fr = max(m.b0 + m.b1 * ida, piso) * (1 + MARGEM_GREENFIELD)
            (melhor === nothing || fr < melhor[2]) && (melhor = (a, fr, m))
        end
        melhor === nothing || push!(cands, (pol, pod, ida, melhor[1], melhor[2], melhor[3]))
    end
    sort!(cands; by = x -> x[5])

    extras = Any[]
    rel = DataFrame(POL = String[], POD = String[], ARMADOR = String[], TEMPO_ESTIMADO = Int[],
        FRETE_ESTIMADO_TON = Float64[], ERRO_PADRAO_REGRESSAO_TON = Float64[], N_OBS = Int[],
        MARGEM_APLICADA_PCT = Float64[])
    for (k, (pol, pod, ida, a, fr, m)) in enumerate(first(cands, GREENFIELD_MAX_CANDIDATAS))
        rs_a = [r for r in simples if r.armador == a]
        isempty(rs_a) && (rs_a = simples)
        min_in = median(Float64[r.min_in for r in rs_a])
        max_in = median(Float64[r.max_in for r in rs_a])
        volta  = arred(median(Float64[Float64(r.volta) for r in rs_a]))
        lag    = ida + tempo_oper(pol) + tempo_oper(pod)
        ciclo  = max(1, ida + volta + tempo_oper(pol) + tempo_oper(pod))
        push!(extras, (id = -k, armador = a, origens = [pol], destinos = [pod], frete = fr,
                       min_in = min_in, max_in = max_in, lag_desc = [lag], ciclo = ciclo,
                       ida = ida, volta = volta))
        push!(rel, (pol, pod, a, ida, fr * ESCALA_MOEDA / ESCALA_TON, m.s * ESCALA_MOEDA / ESCALA_TON,
                    m.n, 100 * MARGEM_GREENFIELD))
    end
    return extras, rel
end

function analisar_greenfield(base)
    extras, rel = estimar_greenfield(rotas_base)
    if isempty(extras)
        println("Greenfield: nenhum corredor novo candidato (todos os pares POL-POD já têm rota).")
        return nothing
    end
    mkpath(DIR_SAIDA)
    CSV.write(joinpath(DIR_SAIDA, "greenfield_candidatas.csv"), rel; delim = ';', decimal = ',')
    println("Greenfield: ", length(extras), " rotas candidatas estimadas (margem de segurança ",
            round(100 * MARGEM_GREENFIELD, digits = 1), " %).")
    R = resolver(Cenario(nome = "greenfield"); rotas_pre = vcat(base[:rotas_modelo], extras),
                 tempo_limite = TEMPO_LIMITE_CENARIO_S)
    R[:tem_solucao] || return R
    usadas = DataFrame(ID_GREENFIELD = Int[], ARMADOR = String[], POL = String[], POD = String[],
                       VIAGENS = Float64[], TON = Float64[])
    for ((rid, t), nv) in R[:res].navios
        r = R[:rotas_modelo][rid]
        r.id_orig < 0 || continue
        nvv = value(nv)
        nvv > 1e-4 || continue
        tot = ESCALA_TON * sum(value(R[:res].y[(rid, k, j, t)]) for (k, j) in R[:res].segmentos[(rid, t)])
        push!(usadas, (r.id_orig, r.armador, r.origens[1], r.destinos[1], nvv, tot))
    end
    if nrow(usadas) > 0
        usadas = combine(groupby(usadas, [:ID_GREENFIELD, :ARMADOR, :POL, :POD]),
                         :VIAGENS => sum => :VIAGENS, :TON => sum => :TON)
        CSV.write(joinpath(DIR_SAIDA, "greenfield_rotas_usadas.csv"), usadas; delim = ';', decimal = ',')
    end
    dlucro = R[:resumo].lucro_objetivo - base[:resumo].lucro_objetivo
    println("Greenfield: rotas novas usadas = ", nrow(usadas), " | variação do lucro vs base = ", dlucro,
            "  (lembre: fretes de rotas novas são ESTIMADOS; teste também MARGEM_GREENFIELD maiores)")
    return R
end


# =====================================================================
# SENSIBILIDADE AO PRÉ-FILTRO (heurístico)
# =====================================================================
function sensibilidade_prefiltro(ks = (1, 3, 5, 0))
    linhas = DataFrame(K = Int[], N_ROTAS = Int[], LUCRO = Float64[], LIMITE_SUPERIOR = Float64[],
                       DISTANCIA_PCT = Float64[])
    for k in ks
        univ = renumerar(prefiltro_por_corredor(rotas_dominadas, k))
        R = resolver(Cenario(nome = "prefiltro_k$(k)"); universo = univ, exportar = false)
        R[:tem_solucao] || continue
        lucro = R[:resumo].lucro_objetivo
        ub = ESCALA_MOEDA * R[:obj_relaxacao]
        push!(linhas, (k, length(univ), lucro, ub, 100 * (ub - lucro) / abs(ub)))
    end
    mkpath(DIR_SAIDA)
    CSV.write(joinpath(DIR_SAIDA, "sensibilidade_prefiltro.csv"), linhas; delim = ';', decimal = ',')
    println(linhas)
    return linhas
end


# =====================================================================
# OPORTUNIDADES PARA A LIDERANÇA (reaproveita as rotas da base: fase exata apenas)
#   1) Estoque de segurança 15/10/5/0 dias: economia e risco (violação, backlog, spot)
#   2) Recusa livre: quais clientes deixam de ser atendidos (deficitários)
#   3) Expansão de +EXPANSAO_CAPACIDADE_PCT em cada fábrica: valor por tonelada adicional
#   4) Greenfield
# =====================================================================
function executar_cenarios(base)
    rotas_ref = base[:rotas_modelo]
    resultados = Dict{Symbol,Any}[base]

    lista = Cenario[]
    for d in (10, 5, 0)
        push!(lista, Cenario(nome = "ss_$(d)d", dias_ss = d))
    end
    push!(lista, Cenario(nome = "recusa_livre", recusar_livre = true))
    for f in F
        push!(lista, Cenario(nome = "exp_" * replace(f, r"[^A-Za-z0-9]" => ""),
                             fator_capacidade = Dict(f => 1 + EXPANSAO_CAPACIDADE_PCT)))
    end

    for cen in lista
        try
            R = resolver(cen; rotas_pre = rotas_ref, tempo_limite = TEMPO_LIMITE_CENARIO_S)
            push!(resultados, R)
        catch err
            @warn "Cenário $(cen.nome) falhou: $err"
        end
    end

    df = vcat([DataFrame([R[:resumo]]) for R in resultados]...)
    df.DELTA_OBJETIVO    = df.lucro_objetivo .- df.lucro_objetivo[1]
    df.DELTA_OPERACIONAL = df.lucro_operacional .- df.lucro_operacional[1]
    mkpath(DIR_SAIDA)
    CSV.write(joinpath(DIR_SAIDA, "comparativo_cenarios.csv"), df; delim = ';', decimal = ',')
    println("\n===== COMPARATIVO DE CENÁRIOS =====")
    println(df[:, [:cenario, :status, :lucro_operacional, :DELTA_OPERACIONAL, :violacao_ss_ton_mes,
                   :backlog_ton_mes, :spot_ton]])

    # Expansão: valor por tonelada adicional produzida
    exp_rows = DataFrame(FABRICA = String[], TON_ADICIONAL = Float64[], DELTA_OPERACIONAL = Float64[],
                         DELTA_OBJETIVO = Float64[], VALOR_POR_TON_OPERACIONAL = Float64[],
                         VALOR_POR_TON_OBJETIVO = Float64[])
    for f in F
        nome = "exp_" * replace(f, r"[^A-Za-z0-9]" => "")
        i = findfirst(==(nome), df.cenario)
        i === nothing && continue
        ton_add = ESCALA_TON * EXPANSAO_CAPACIDADE_PCT * sum(get(volume_producao, (f, t), 0.0) for t in T)
        ton_add > 0 || continue
        push!(exp_rows, (f, ton_add, df.DELTA_OPERACIONAL[i], df.DELTA_OBJETIVO[i],
                         df.DELTA_OPERACIONAL[i] / ton_add, df.DELTA_OBJETIVO[i] / ton_add))
    end
    if nrow(exp_rows) > 0
        sort!(exp_rows, :VALOR_POR_TON_OBJETIVO; rev = true)
        CSV.write(joinpath(DIR_SAIDA, "oportunidades_expansao_fabricas.csv"), exp_rows; delim = ';', decimal = ',')
        println("\nExpansão de fábricas (ranking por valor por tonelada adicional):")
        println(exp_rows)
    end

    # Clientes deficitários: margem negativa na base e/ou não atendidos com recusa livre
    livre = findfirst(R -> R[:cenario] == "recusa_livre" && R[:tem_solucao], resultados)
    if livre !== nothing && base[:tem_solucao]
        rl = select(resultados[livre][:rentabilidade], :CLIENTE, :ATENDIDO_PCT => :ATENDIDO_PCT_RECUSA_LIVRE)
        cli = leftjoin(base[:rentabilidade], rl; on = :CLIENTE)
        cli.NAO_ATENDIDO_NA_RECUSA_LIVRE = coalesce.(cli.ATENDIDO_PCT_RECUSA_LIVRE, 0.0) .< 50.0
        CSV.write(joinpath(DIR_SAIDA, "oportunidades_clientes_deficitarios.csv"), cli; delim = ';', decimal = ',')
        def = cli[cli.PREJUIZO .| cli.NAO_ATENDIDO_NA_RECUSA_LIVRE, :]
        println("\nClientes deficitários (margem negativa ou recusados no modo livre): ", nrow(def),
                " | ", round(sum(def.PARTICIPACAO_VOLUME_PCT), digits = 2), " % do volume | ",
                round(sum(def.PARTICIPACAO_RECEITA_PCT), digits = 2), " % da receita")
    end

    try
        analisar_greenfield(base)
    catch err
        @warn "Análise greenfield falhou: $err"
    end
    return df
end


# =====================================================================
# EXECUÇÃO PRINCIPAL
# =====================================================================
R_base = resolver(Cenario())

# variáveis disponíveis no REPL para inspeção (ids das rotas = posição em rotas_modelo; id_orig = linha no CSV)
if R_base[:tem_solucao] || haskey(R_base, :res)
    res = R_base[:res]
    model = res.model;       estoque = res.estoque;   load = res.load;       unload = res.unload
    folga_ss = res.folga_ss; producao = res.producao; fab_pol = res.fab_pol; vendas = res.vendas
    backlog = res.backlog;   spot = res.spot;         navios = res.navios;   faixa = res.faixa
    y = res.y;               xf = res.xf;             segmentos = res.segmentos; trechos = res.trechos
end

if EXECUTAR_CENARIOS && R_base[:tem_solucao]
    executar_cenarios(R_base)
    # sensibilidade_prefiltro()   # opcional: mede o efeito do pré-filtro heurístico (demorado)
end