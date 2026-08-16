$Origem = "D:\VideosCurtos"
$Destino = "C:\VideoSaida"

# Nome do arquivo final
$ArquivoSaida = Join-Path $Destino "VideosConcatenados.mp4"

# Arquivos temporários
$ListaFFmpeg = Join-Path $env:TEMP "lista_videos_ffmpeg.txt"
$Relatorio = Join-Path $Destino "ordem_videos.txt"

# Cria a pasta de destino
if (-not (Test-Path $Destino)) {
    New-Item -ItemType Directory -Path $Destino | Out-Null
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " CONCATENACAO DE VIDEOS DO IPHONE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# Verifica FFmpeg
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: ffmpeg nao foi encontrado no PATH." -ForegroundColor Red
    exit
}

# Verifica FFprobe
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: ffprobe nao foi encontrado no PATH." -ForegroundColor Red
    exit
}

Write-Host "Buscando videos..." -ForegroundColor Yellow

$Arquivos = Get-ChildItem -Path $Origem -Filter "*.mov" -File -Recurse

if ($Arquivos.Count -eq 0) {
    Write-Host "Nenhum arquivo .mov encontrado em $Origem" -ForegroundColor Red
    exit
}

Write-Host "Encontrados: $($Arquivos.Count) videos"
Write-Host ""

# Array para armazenar os metadados
$Videos = @()

$Contador = 0

foreach ($Arquivo in $Arquivos) {

    $Contador++

    Write-Progress `
        -Activity "Lendo metadados dos videos" `
        -Status "$Contador de $($Arquivos.Count): $($Arquivo.Name)" `
        -PercentComplete (($Contador / $Arquivos.Count) * 100)

    # Obtém o creation_time do video
    $CreationTime = & ffprobe `
        -v error `
        -select_streams v:0 `
        -show_entries format_tags=creation_time `
        -of default=noprint_wrappers=1:nokey=1 `
        "$($Arquivo.FullName)" 2>$null

    $CreationTime = ($CreationTime | Select-Object -First 1).Trim()

    # Se nao encontrou creation_time, tenta o metadata do stream de video
    if ([string]::IsNullOrWhiteSpace($CreationTime)) {

        $CreationTime = & ffprobe `
            -v error `
            -select_streams v:0 `
            -show_entries stream_tags=creation_time `
            -of default=noprint_wrappers=1:nokey=1 `
            "$($Arquivo.FullName)" 2>$null

        $CreationTime = ($CreationTime | Select-Object -First 1).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($CreationTime)) {

        Write-Host ""
        Write-Host "ATENCAO: Sem creation_time: $($Arquivo.FullName)" -ForegroundColor Yellow

        # Usa a data do arquivo apenas como fallback
        $DataOrdenacao = $Arquivo.CreationTime

    }
    else {

        try {
            $DataOrdenacao = [DateTimeOffset]::Parse($CreationTime)
        }
        catch {
            Write-Host ""
            Write-Host "ATENCAO: Nao foi possivel interpretar creation_time:" -ForegroundColor Yellow
            Write-Host "$CreationTime"
            Write-Host "$($Arquivo.FullName)"

            $DataOrdenacao = $Arquivo.CreationTime
        }
    }

    $Videos += [PSCustomObject]@{
        Arquivo      = $Arquivo
        CreationTime = $CreationTime
        Data         = $DataOrdenacao
    }
}

Write-Progress -Activity "Lendo metadados dos videos" -Completed

Write-Host ""
Write-Host "Ordenando videos pela data/hora de gravacao..." -ForegroundColor Yellow

$VideosOrdenados = $Videos | Sort-Object Data

# ============================================================
# Gera relatório para conferência
# ============================================================

$RelatorioLinhas = @()

$Numero = 0

foreach ($Video in $VideosOrdenados) {

    $Numero++

    $DataFormatada = $Video.Data.ToString("yyyy-MM-dd HH:mm:ss")

    $RelatorioLinhas += "{0:D4} | {1} | {2}" -f `
        $Numero,
        $DataFormatada,
        $Video.Arquivo.FullName
}

$RelatorioLinhas | Set-Content -Path $Relatorio -Encoding UTF8

# ============================================================
# Mostra os primeiros videos da ordem
# ============================================================

Write-Host ""
Write-Host "Primeiros videos na ordem de concatenacao:" -ForegroundColor Green
Write-Host ""

$VideosOrdenados |
    Select-Object -First 10 |
    ForEach-Object {
        Write-Host ("{0} -> {1}" -f `
            $_.Data.ToString("yyyy-MM-dd HH:mm:ss"),
            $_.Arquivo.Name)
    }

if ($VideosOrdenados.Count -gt 10) {
    Write-Host ""
    Write-Host "... e mais $($VideosOrdenados.Count - 10) videos."
}

Write-Host ""
Write-Host "Relatorio completo:" -ForegroundColor Cyan
Write-Host $Relatorio

# ============================================================
# Cria lista para o FFmpeg
# ============================================================

Write-Host ""
Write-Host "Criando lista para o FFmpeg..." -ForegroundColor Yellow

$ListaFFmpegLinhas = foreach ($Video in $VideosOrdenados) {

    # Converte caminho para formato absoluto
    # e escapa apostrofos para o formato concat do FFmpeg.
    $Caminho = $Video.Arquivo.FullName.Replace("\", "/")
    $Caminho = $Caminho.Replace("'", "'\''")

    "file '$Caminho'"
}

$Utf8SemBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllLines(
    $ListaFFmpeg,
    $ListaFFmpegLinhas,
    $Utf8SemBom
)

# ============================================================
# Remove arquivo anterior, se existir
# ============================================================

if (Test-Path $ArquivoSaida) {

    Write-Host ""
    Write-Host "O arquivo de saida ja existe:" -ForegroundColor Yellow
    Write-Host $ArquivoSaida
    Write-Host ""

    $Resposta = Read-Host "Deseja substituir? (S/N)"

    if ($Resposta -notmatch "^[Ss]$") {
        Write-Host "Operacao cancelada."
        Remove-Item $ListaFFmpeg -Force -ErrorAction SilentlyContinue
        exit
    }

    Remove-Item $ArquivoSaida -Force
}

# ============================================================
# CONCATENACAO
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " INICIANDO CONCATENACAO" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Arquivos: $($VideosOrdenados.Count)"
Write-Host "Origem:   $Origem"
Write-Host "Destino:  $ArquivoSaida"
Write-Host ""
Write-Host "Modo: STREAM COPY" -ForegroundColor Green
Write-Host "Qualidade: ORIGINAL (sem recodificacao)" -ForegroundColor Green
Write-Host ""

& ffmpeg `
    -hide_banner `
    -f concat `
    -safe 0 `
    -i "$ListaFFmpeg" `
    -map 0:v:0 `
    -map 0:a:0? `
    -c:v h264_nvenc `
    -preset p5 `
    -rc vbr `
    -cq 20 `
    -c:a aac `
    -b:a 192k `
    -fps_mode vfr `
    -movflags +faststart `
    "$ArquivoSaida"

$Codigo = $LASTEXITCODE

# ============================================================
# Limpeza
# ============================================================

Remove-Item $ListaFFmpeg -Force -ErrorAction SilentlyContinue

Write-Host ""

if ($Codigo -eq 0 -and (Test-Path $ArquivoSaida)) {

    $TamanhoGB = (Get-Item $ArquivoSaida).Length / 1GB

    Write-Host "==============================================" -ForegroundColor Green
    Write-Host " CONCLUIDO COM SUCESSO" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Arquivo:"
    Write-Host $ArquivoSaida
    Write-Host ""
    Write-Host ("Tamanho: {0:N2} GB" -f $TamanhoGB)
    Write-Host ""
    Write-Host "Relatorio da ordem:"
    Write-Host $Relatorio
}
else {

    Write-Host "==============================================" -ForegroundColor Red
    Write-Host " ERRO NA CONCATENACAO" -ForegroundColor Red
    Write-Host "==============================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Codigo de retorno do FFmpeg: $Codigo"
}