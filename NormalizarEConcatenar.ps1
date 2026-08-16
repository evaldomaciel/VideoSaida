# ============================================================
# NORMALIZA E CONCATENA VIDEOS DO IPHONE (D:\VideosCurtos)
#
# Estrategia (baseada na analise de InformacoesVideos.txt):
#   - 255 clipes HEVC, porem misturam: SDR bt709 / HDR HLG (bt2020nc)
#     / WCG smpte170m-smpte432, 8-bit e 10-bit, VFR, audio
#     pcm_s16le-mono e aac-estereo, 7 sem audio, orientacoes e
#     resolucoes diferentes. Por isso "-c copy" e concat direto
#     falham (dessincronia / erros de rematrix de audio).
#   - Etapa 1: cada clipe e normalizado individualmente (mesmo
#     codec, mesma moldura, mesmo espaco de cor SDR bt709, mesmo
#     audio AAC estereo 44.1kHz, mesmo FPS constante) usando a
#     GTX 1050 (hevc_nvenc). E o UNICO ponto de recodificacao.
#   - Etapa 2: os arquivos normalizados (agora identicos em
#     formato) sao concatenados com "-c copy" - instantaneo e
#     sem perda, pois so ha uma geracao de recodificacao no total.
#
# Ordenacao cronologica: com.apple.quicktime.creationdate (hora
# local gravada pelo iPhone - e o campo que bate com "Midia
# criada" do Windows). Fallback: creation_time (UTC) e por
# ultimo LastWriteTime do arquivo.
# ============================================================

param(
    [switch]$Reprocessar
)

$Origem             = "D:\VideosCurtos"
$Destino            = "C:\VideoSaida"
$PastaNormalizados  = Join-Path $Destino "Normalizados"
$ArquivoSaida       = Join-Path $Destino "VideosConcatenados.mp4"
$RelatorioOrdem     = Join-Path $Destino "ordem_videos.txt"
$ListaConcat        = Join-Path $Destino "lista_concat.txt"
$LogNormalizacao    = Join-Path $Destino "log_normalizacao.txt"

# Config de saida (definida com o usuario e validada com testes reais
# em amostras SDR / HDR / sem-audio antes de rodar nos 255 arquivos -
# ver notas abaixo sobre os parametros do NVENC)
$CanvasW     = 1440
$CanvasH     = 1920
$FPS         = 60
$SampleRate  = 44100
$Preset      = "p6"

# NOTA: "-temporal_aq" falha na GTX 1050 (Pascal nao suporta -> "No
# capable devices found"). "-cq" em modo irrestrito (b:v 0) gerou
# arquivos ~30-40% maiores que os originais nos testes. Por isso
# usamos VBR com teto de bitrate (val. em testes: ficou MENOR que a
# soma dos originais nas 3 amostras testadas: SDR, HDR e sem-audio).
$BitrateAlvo = "15M"
$BitrateMax  = "22M"
$BufSize     = "30M"
$AQStrength  = 8

$Extensoes = @("*.mov", "*.mp4", "*.m4v")

# ------------------------------------------------------------
# Preparacao
# ------------------------------------------------------------

if (-not (Test-Path $Origem)) {
    Write-Host "ERRO: A pasta nao existe: $Origem" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: ffmpeg nao foi encontrado no PATH." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: ffprobe nao foi encontrado no PATH." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $PastaNormalizados)) {
    New-Item -ItemType Directory -Path $PastaNormalizados | Out-Null
}

if (Test-Path $LogNormalizacao) {
    Remove-Item $LogNormalizacao -Force
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " NORMALIZACAO + CONCATENACAO DE VIDEOS DO IPHONE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# Localiza arquivos
# ------------------------------------------------------------

Write-Host "Buscando videos em $Origem..." -ForegroundColor Yellow

$Arquivos = foreach ($Extensao in $Extensoes) {
    Get-ChildItem -Path $Origem -Filter $Extensao -File -Recurse -ErrorAction SilentlyContinue
}
$Arquivos = $Arquivos | Sort-Object FullName -Unique

if ($Arquivos.Count -eq 0) {
    Write-Host "Nenhum video encontrado em $Origem" -ForegroundColor Red
    exit 1
}

Write-Host "Encontrados: $($Arquivos.Count) videos"
Write-Host ""

# ------------------------------------------------------------
# Le metadados de cada arquivo (data real de gravacao, presenca
# de audio, espaco de cor) via ffprobe -show_format -show_streams
# ------------------------------------------------------------

function Get-TagValue($Tags, $Nome) {
    if ($null -eq $Tags) { return $null }
    $Prop = $Tags.PSObject.Properties | Where-Object { $_.Name -eq $Nome } | Select-Object -First 1
    if ($null -eq $Prop) { return $null }
    return [string]$Prop.Value
}

$Videos = @()
$Contador = 0
$SemDataExata = 0

foreach ($Arquivo in $Arquivos) {

    $Contador++
    Write-Progress -Activity "Lendo metadados dos videos" `
        -Status "$Contador de $($Arquivos.Count): $($Arquivo.Name)" `
        -PercentComplete (($Contador / $Arquivos.Count) * 100)

    $Json = & ffprobe -v quiet -print_format json -show_format -show_streams "$($Arquivo.FullName)" 2>$null
    $Info = $null
    if ($Json) {
        try { $Info = $Json | ConvertFrom-Json } catch { $Info = $null }
    }

    if ($null -eq $Info) {
        Write-Host "ATENCAO: ffprobe falhou em $($Arquivo.FullName)" -ForegroundColor Yellow
        continue
    }

    # --- Data/hora real de gravacao ---
    $DataOrdenacao = $null
    $FonteData = ""

    $QtCreationDate = Get-TagValue $Info.format.tags "com.apple.quicktime.creationdate"
    if ($null -ne $QtCreationDate) {
        try {
            $DataOrdenacao = [DateTimeOffset]::Parse($QtCreationDate)
            $FonteData = "com.apple.quicktime.creationdate"
        } catch {}
    }

    if ($null -eq $DataOrdenacao) {
        $CreationTimeUtc = Get-TagValue $Info.format.tags "creation_time"
        if ($null -ne $CreationTimeUtc) {
            try {
                $DataOrdenacao = [DateTimeOffset]::Parse($CreationTimeUtc)
                $FonteData = "creation_time (UTC)"
            } catch {}
        }
    }

    if ($null -eq $DataOrdenacao) {
        $DataOrdenacao = [DateTimeOffset]$Arquivo.LastWriteTime
        $FonteData = "LastWriteTime (fallback - sem metadado)"
        $SemDataExata++
    }

    # --- Stream de video / audio ---
    $StreamVideo = $Info.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $StreamAudio = $Info.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    $TemAudio = $null -ne $StreamAudio

    $ColorTransfer = ""
    if ($null -ne $StreamVideo -and $null -ne $StreamVideo.color_transfer) {
        $ColorTransfer = $StreamVideo.color_transfer
    }
    $EhHDR = ($ColorTransfer -eq "arib-std-b67" -or $ColorTransfer -eq "smpte2084")

    $Videos += [PSCustomObject]@{
        Arquivo   = $Arquivo
        Data      = $DataOrdenacao
        FonteData = $FonteData
        TemAudio  = $TemAudio
        EhHDR     = $EhHDR
    }
}

Write-Progress -Activity "Lendo metadados dos videos" -Completed

if ($SemDataExata -gt 0) {
    Write-Host ""
    Write-Host "ATENCAO: $SemDataExata arquivo(s) sem creation_time/creationdate - usada data do arquivo como fallback." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Ordenando cronologicamente (com.apple.quicktime.creationdate)..." -ForegroundColor Yellow

$VideosOrdenados = $Videos | Sort-Object Data

# ------------------------------------------------------------
# Relatorio da ordem final
# ------------------------------------------------------------

$RelatorioLinhas = @()
$Numero = 0

foreach ($Video in $VideosOrdenados) {

    $Numero++
    $DataFormatada = $Video.Data.ToString("yyyy-MM-dd HH:mm:ss zzz")

    $Flags = @()
    if ($Video.EhHDR)      { $Flags += "HDR->SDR" }
    if (-not $Video.TemAudio) { $Flags += "SEM AUDIO (silencio adicionado)" }
    if ($Video.FonteData -ne "com.apple.quicktime.creationdate") { $Flags += "data: $($Video.FonteData)" }

    $FlagsTexto = ""
    if ($Flags.Count -gt 0) { $FlagsTexto = " | " + ($Flags -join ", ") }

    $RelatorioLinhas += "{0:D4} | {1} | {2}{3}" -f `
        $Numero, $DataFormatada, $Video.Arquivo.FullName, $FlagsTexto
}

$Utf8SemBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($RelatorioOrdem, $RelatorioLinhas, $Utf8SemBom)

Write-Host "Relatorio da ordem: $RelatorioOrdem"
Write-Host ""

# ------------------------------------------------------------
# ETAPA 1: normalizacao individual (unica recodificacao)
# ------------------------------------------------------------

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " ETAPA 1/2: NORMALIZANDO $($VideosOrdenados.Count) CLIPES (GTX 1050 / hevc_nvenc)" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

$FiltroSDR = "zscale=t=bt709:m=bt709:p=bt709:r=tv,format=yuv420p,scale=$($CanvasW):$($CanvasH):force_original_aspect_ratio=decrease,pad=$($CanvasW):$($CanvasH):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=$FPS"
$FiltroHDR = "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,scale=$($CanvasW):$($CanvasH):force_original_aspect_ratio=decrease,pad=$($CanvasW):$($CanvasH):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=$FPS"

$Normalizados = @()
$Falhas = @()
$Numero = 0

foreach ($Video in $VideosOrdenados) {

    $Numero++
    $NomeSaida = "{0:D4}.mp4" -f $Numero
    $CaminhoSaida = Join-Path $PastaNormalizados $NomeSaida

    Write-Progress -Activity "Normalizando clipes" `
        -Status "$Numero de $($VideosOrdenados.Count): $($Video.Arquivo.Name)" `
        -PercentComplete (($Numero / $VideosOrdenados.Count) * 100)

    if ((Test-Path $CaminhoSaida) -and -not $Reprocessar) {
        $Normalizados += $CaminhoSaida
        continue
    }

    if ($Video.EhHDR) {
        $FiltroVideo = $FiltroHDR
    } else {
        $FiltroVideo = $FiltroSDR
    }

    $CreationUtc = $Video.Data.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000000Z")

    $ArgsFFmpeg = @("-hide_banner", "-y", "-i", $Video.Arquivo.FullName)

    if (-not $Video.TemAudio) {
        $ArgsFFmpeg += @("-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=$SampleRate")
        $MapAudio = "1:a:0"
    } else {
        $MapAudio = "0:a:0"
    }

    $ArgsFFmpeg += @(
        "-map", "0:v:0",
        "-map", $MapAudio,
        "-vf", $FiltroVideo,
        "-af", "aformat=sample_fmts=fltp:sample_rates=$($SampleRate):channel_layouts=stereo",
        "-c:v", "hevc_nvenc",
        "-preset", $Preset,
        "-rc", "vbr",
        "-b:v", $BitrateAlvo,
        "-maxrate", $BitrateMax,
        "-bufsize", $BufSize,
        "-spatial_aq", "1",
        "-aq-strength", "$AQStrength",
        "-b_ref_mode", "disabled",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", "160k",
        "-ar", "$SampleRate",
        "-ac", "2",
        "-metadata", "creation_time=$CreationUtc"
    )

    if (-not $Video.TemAudio) {
        $ArgsFFmpeg += "-shortest"
    }

    $ArgsFFmpeg += $CaminhoSaida

    "===== $($Video.Arquivo.FullName) =====" | Out-File -FilePath $LogNormalizacao -Append -Encoding utf8
    & ffmpeg @ArgsFFmpeg 2>> $LogNormalizacao

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $CaminhoSaida)) {
        Write-Host "ERRO ao normalizar: $($Video.Arquivo.FullName)" -ForegroundColor Red
        $Falhas += $Video.Arquivo.FullName
        continue
    }

    $Normalizados += $CaminhoSaida
}

Write-Progress -Activity "Normalizando clipes" -Completed

Write-Host ""
Write-Host "Normalizados com sucesso: $($Normalizados.Count) de $($VideosOrdenados.Count)"

if ($Falhas.Count -gt 0) {
    Write-Host ""
    Write-Host "ATENCAO: $($Falhas.Count) arquivo(s) falharam na normalizacao (ver $LogNormalizacao):" -ForegroundColor Red
    $Falhas | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if ($Normalizados.Count -eq 0) {
    Write-Host "Nenhum arquivo normalizado com sucesso. Abortando." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# ETAPA 2: concatenacao (stream copy - arquivos ja uniformes)
# ------------------------------------------------------------

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " ETAPA 2/2: CONCATENANDO (stream copy, sem perda)" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

$ListaLinhas = foreach ($Caminho in $Normalizados) {
    $CaminhoNormalizado = $Caminho.Replace("\", "/").Replace("'", "'\''")
    "file '$CaminhoNormalizado'"
}

[System.IO.File]::WriteAllLines($ListaConcat, $ListaLinhas, $Utf8SemBom)

if (Test-Path $ArquivoSaida) {
    Remove-Item $ArquivoSaida -Force
}

& ffmpeg -hide_banner -y `
    -f concat -safe 0 -i "$ListaConcat" `
    -map 0:v:0 -map 0:a:0 `
    -c copy `
    -movflags +faststart `
    "$ArquivoSaida"

$Codigo = $LASTEXITCODE

Remove-Item $ListaConcat -Force -ErrorAction SilentlyContinue

Write-Host ""

if ($Codigo -eq 0 -and (Test-Path $ArquivoSaida)) {

    $TamanhoGB = (Get-Item $ArquivoSaida).Length / 1GB

    Write-Host "==============================================" -ForegroundColor Green
    Write-Host " CONCLUIDO COM SUCESSO" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Arquivo final: $ArquivoSaida"
    Write-Host ("Tamanho: {0:N2} GB" -f $TamanhoGB)
    Write-Host "Relatorio da ordem: $RelatorioOrdem"
    Write-Host "Clipes normalizados (intermediarios): $PastaNormalizados"
    if ($Falhas.Count -gt 0) {
        Write-Host ""
        Write-Host "$($Falhas.Count) arquivo(s) original(is) NAO entraram no video final (ver acima)." -ForegroundColor Yellow
    }
}
else {
    Write-Host "==============================================" -ForegroundColor Red
    Write-Host " ERRO NA CONCATENACAO FINAL" -ForegroundColor Red
    Write-Host "==============================================" -ForegroundColor Red
    Write-Host "Codigo de retorno do FFmpeg: $Codigo"
}
