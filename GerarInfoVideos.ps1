# ============================================================
# GERAR RELATORIO TECNICO DOS VIDEOS
# ============================================================

$Origem = "D:\VideosCurtos"
$Destino = "C:\VideoSaida"
$Relatorio = Join-Path $Destino "InformacoesVideos.txt"

# ------------------------------------------------------------
# Preparacao
# ------------------------------------------------------------

if (-not (Test-Path $Origem)) {
    Write-Host "ERRO: A pasta nao existe: $Origem" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Destino)) {
    New-Item -ItemType Directory -Path $Destino | Out-Null
}

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: ffprobe nao foi encontrado no PATH." -ForegroundColor Red
    exit 1
}

# Extensoes que vamos analisar
$Extensoes = @(
    "*.mov",
    "*.mp4",
    "*.m4v"
)

# ------------------------------------------------------------
# Localiza arquivos
# ------------------------------------------------------------

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " GERANDO RELATORIO DOS VIDEOS" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Origem: $Origem"
Write-Host "Destino: $Relatorio"
Write-Host ""

$Arquivos = foreach ($Extensao in $Extensoes) {
    Get-ChildItem `
        -Path $Origem `
        -Filter $Extensao `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue
}

# Remove eventuais duplicidades
$Arquivos = $Arquivos |
    Sort-Object FullName -Unique

if ($Arquivos.Count -eq 0) {
    Write-Host "Nenhum video encontrado." -ForegroundColor Red
    exit 1
}

Write-Host "Videos encontrados: $($Arquivos.Count)" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Funcao para executar ffprobe e obter JSON
# ------------------------------------------------------------

function Get-FFProbeJson {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Arquivo
    )

    $Argumentos = @(
        "-hide_banner",
        "-v", "quiet",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        "-show_chapters",
        "-show_programs",
        "-show_data",
        $Arquivo
    )

    $Json = & ffprobe @Argumentos 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($Json -join ""))) {
        return $null
    }

    try {
        return ($Json -join "`n") | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

# ------------------------------------------------------------
# Arrays para resumo estatistico
# ------------------------------------------------------------

$Resultados = @()

$Contador = 0

# ------------------------------------------------------------
# Analise dos arquivos
# ------------------------------------------------------------

foreach ($Arquivo in $Arquivos) {

    $Contador++

    $Percentual = [math]::Round(
        ($Contador / $Arquivos.Count) * 100,
        1
    )

    Write-Progress `
        -Activity "Analisando videos" `
        -Status "$Contador de $($Arquivos.Count) - $($Arquivo.Name)" `
        -PercentComplete $Percentual

    Write-Host ("[{0}/{1}] {2}" -f `
        $Contador,
        $Arquivos.Count,
        $Arquivo.Name)

    $Info = Get-FFProbeJson -Arquivo $Arquivo.FullName

    if ($null -eq $Info) {

        Write-Host "  ERRO ao analisar arquivo." -ForegroundColor Red

        $Resultados += [PSCustomObject]@{
            Arquivo = $Arquivo
            Info = $null
            Erro = $true
        }

        continue
    }

    $Resultados += [PSCustomObject]@{
        Arquivo = $Arquivo
        Info = $Info
        Erro = $false
    }
}

Write-Progress -Activity "Analisando videos" -Completed

# ------------------------------------------------------------
# Funcao para escrever linha no relatorio
# ------------------------------------------------------------

$Linhas = [System.Collections.Generic.List[string]]::new()

function Add-Line {
    param (
        [AllowEmptyString()]
        [string]$Texto = ""
    )

    $script:Linhas.Add($Texto)
}

function Add-Section {
    param (
        [string]$Titulo
    )

    Add-Line ""
    Add-Line "============================================================"
    Add-Line $Titulo
    Add-Line "============================================================"
}

# ------------------------------------------------------------
# Cabecalho
# ------------------------------------------------------------

Add-Line "RELATORIO TECNICO DOS VIDEOS"
Add-Line "Gerado em: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Origem: $Origem"
Add-Line "Quantidade de arquivos: $($Arquivos.Count)"
Add-Line ""

# ------------------------------------------------------------
# Informacoes detalhadas de cada arquivo
# ------------------------------------------------------------

$NumeroArquivo = 0

foreach ($Resultado in $Resultados) {

    $NumeroArquivo++

    $Arquivo = $Resultado.Arquivo
    $Info = $Resultado.Info

    Add-Line ""
    Add-Line "################################################################"
    Add-Line "ARQUIVO $("{0:D4}" -f $NumeroArquivo)"
    Add-Line "################################################################"

    Add-Line ""
    Add-Line "[ARQUIVO]"
    Add-Line "Nome: $($Arquivo.Name)"
    Add-Line "Caminho: $($Arquivo.FullName)"
    Add-Line "Extensao: $($Arquivo.Extension)"
    Add-Line ("Tamanho bytes: {0}" -f $Arquivo.Length)
    Add-Line ("Tamanho MB: {0:N2}" -f ($Arquivo.Length / 1MB))
    Add-Line ("Tamanho GB: {0:N4}" -f ($Arquivo.Length / 1GB))
    Add-Line "Data Windows CreationTime: $($Arquivo.CreationTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
    Add-Line "Data Windows LastWriteTime: $($Arquivo.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss.fff'))"

    if ($Resultado.Erro) {
        Add-Line ""
        Add-Line "ERRO: ffprobe nao conseguiu analisar este arquivo."
        continue
    }

    $Format = $Info.format

    # --------------------------------------------------------
    # FORMAT
    # --------------------------------------------------------

    Add-Line ""
    Add-Line "[FORMAT]"

    if ($null -ne $Format) {

        Add-Line "filename: $($Format.filename)"
        Add-Line "format_name: $($Format.format_name)"
        Add-Line "format_long_name: $($Format.format_long_name)"
        Add-Line "start_time: $($Format.start_time)"
        Add-Line "duration: $($Format.duration)"
        Add-Line "size: $($Format.size)"
        Add-Line "bit_rate: $($Format.bit_rate)"
        Add-Line "probe_score: $($Format.probe_score)"

        if ($null -ne $Format.tags) {

            Add-Line ""
            Add-Line "[FORMAT TAGS]"

            $Format.tags.PSObject.Properties |
                Sort-Object Name |
                ForEach-Object {
                    Add-Line "$($_.Name): $($_.Value)"
                }
        }
    }

    # --------------------------------------------------------
    # STREAMS
    # --------------------------------------------------------

    $Streams = @($Info.streams)

    Add-Line ""
    Add-Line "[STREAMS]"
    Add-Line "Quantidade de streams: $($Streams.Count)"

    foreach ($Stream in $Streams) {

        Add-Line ""
        Add-Line "------------------------------------------------------------"
        Add-Line "STREAM $($Stream.index)"
        Add-Line "------------------------------------------------------------"

        Add-Line "index: $($Stream.index)"
        Add-Line "codec_type: $($Stream.codec_type)"
        Add-Line "codec_name: $($Stream.codec_name)"
        Add-Line "codec_long_name: $($Stream.codec_long_name)"
        Add-Line "profile: $($Stream.profile)"
        Add-Line "level: $($Stream.level)"
        Add-Line "codec_tag_string: $($Stream.codec_tag_string)"
        Add-Line "codec_tag: $($Stream.codec_tag)"

        Add-Line "start_time: $($Stream.start_time)"
        Add-Line "duration: $($Stream.duration)"
        Add-Line "time_base: $($Stream.time_base)"
        Add-Line "start_pts: $($Stream.start_pts)"
        Add-Line "start_dts: $($Stream.start_dts)"
        Add-Line "duration_ts: $($Stream.duration_ts)"
        Add-Line "nb_frames: $($Stream.nb_frames)"

        # ----------------------------------------------------
        # VIDEO
        # ----------------------------------------------------

        if ($Stream.codec_type -eq "video") {

            Add-Line ""
            Add-Line "[VIDEO]"

            Add-Line "width: $($Stream.width)"
            Add-Line "height: $($Stream.height)"
            Add-Line "coded_width: $($Stream.coded_width)"
            Add-Line "coded_height: $($Stream.coded_height)"
            Add-Line "pix_fmt: $($Stream.pix_fmt)"
            Add-Line "r_frame_rate: $($Stream.r_frame_rate)"
            Add-Line "avg_frame_rate: $($Stream.avg_frame_rate)"
            Add-Line "field_order: $($Stream.field_order)"
            Add-Line "bits_per_raw_sample: $($Stream.bits_per_raw_sample)"

            Add-Line "color_range: $($Stream.color_range)"
            Add-Line "color_space: $($Stream.color_space)"
            Add-Line "color_transfer: $($Stream.color_transfer)"
            Add-Line "color_primaries: $($Stream.color_primaries)"

            Add-Line "has_b_frames: $($Stream.has_b_frames)"
            Add-Line "sample_aspect_ratio: $($Stream.sample_aspect_ratio)"
            Add-Line "display_aspect_ratio: $($Stream.display_aspect_ratio)"

            if ($null -ne $Stream.tags) {

                Add-Line ""
                Add-Line "[VIDEO TAGS]"

                $Stream.tags.PSObject.Properties |
                    Sort-Object Name |
                    ForEach-Object {
                        Add-Line "$($_.Name): $($_.Value)"
                    }
            }

            if ($null -ne $Stream.side_data_list) {

                Add-Line ""
                Add-Line "[VIDEO SIDE DATA]"

                $Stream.side_data_list |
                    ForEach-Object {

                        $_.PSObject.Properties |
                            Sort-Object Name |
                            ForEach-Object {
                                Add-Line "$($_.Name): $($_.Value)"
                            }

                        Add-Line ""
                    }
            }
        }

        # ----------------------------------------------------
        # AUDIO
        # ----------------------------------------------------

        if ($Stream.codec_type -eq "audio") {

            Add-Line ""
            Add-Line "[AUDIO]"

            Add-Line "sample_fmt: $($Stream.sample_fmt)"
            Add-Line "sample_rate: $($Stream.sample_rate)"
            Add-Line "channels: $($Stream.channels)"
            Add-Line "channel_layout: $($Stream.channel_layout)"
            Add-Line "bits_per_sample: $($Stream.bits_per_sample)"
            Add-Line "initial_padding: $($Stream.initial_padding)"
            Add-Line "trailing_padding: $($Stream.trailing_padding)"

            if ($null -ne $Stream.tags) {

                Add-Line ""
                Add-Line "[AUDIO TAGS]"

                $Stream.tags.PSObject.Properties |
                    Sort-Object Name |
                    ForEach-Object {
                        Add-Line "$($_.Name): $($_.Value)"
                    }
            }

            if ($null -ne $Stream.side_data_list) {

                Add-Line ""
                Add-Line "[AUDIO SIDE DATA]"

                $Stream.side_data_list |
                    ForEach-Object {

                        $_.PSObject.Properties |
                            Sort-Object Name |
                            ForEach-Object {
                                Add-Line "$($_.Name): $($_.Value)"
                            }

                        Add-Line ""
                    }
            }
        }
    }

    # --------------------------------------------------------
    # CHAPTERS
    # --------------------------------------------------------

    $Chapters = @($Info.chapters)

    if ($Chapters.Count -gt 0) {

        Add-Line ""
        Add-Line "[CHAPTERS]"

        foreach ($Chapter in $Chapters) {

            Add-Line "id: $($Chapter.id)"
            Add-Line "start: $($Chapter.start)"
            Add-Line "end: $($Chapter.end)"
            Add-Line "time_base: $($Chapter.time_base)"

            if ($null -ne $Chapter.tags) {

                $Chapter.tags.PSObject.Properties |
                    Sort-Object Name |
                    ForEach-Object {
                        Add-Line "$($_.Name): $($_.Value)"
                    }
            }

            Add-Line ""
        }
    }

    # --------------------------------------------------------
    # PROGRAMS
    # --------------------------------------------------------

    $Programs = @($Info.programs)

    if ($Programs.Count -gt 0) {

        Add-Line ""
        Add-Line "[PROGRAMS]"

        foreach ($Program in $Programs) {

            Add-Line "program_id: $($Program.program_id)"
            Add-Line "program_num: $($Program.program_num)"

            if ($null -ne $Program.tags) {

                $Program.tags.PSObject.Properties |
                    Sort-Object Name |
                    ForEach-Object {
                        Add-Line "$($_.Name): $($_.Value)"
                    }
            }
        }
    }

    # --------------------------------------------------------
    # JSON BRUTO
    # --------------------------------------------------------

    Add-Line ""
    Add-Line "[FFPROBE JSON COMPLETO]"

    try {

        $JsonCompleto = $Info |
            ConvertTo-Json -Depth 30

        foreach ($Linha in ($JsonCompleto -split "`r?`n")) {
            Add-Line $Linha
        }

    }
    catch {

        Add-Line "Nao foi possivel gerar JSON completo."
    }
}

# ------------------------------------------------------------
# RESUMO ESTATISTICO
# ------------------------------------------------------------

Add-Section "RESUMO ESTATISTICO"

$Validos = $Resultados |
    Where-Object { -not $_.Erro }

$ComErro = $Resultados |
    Where-Object { $_.Erro }

Add-Line "Total de arquivos: $($Resultados.Count)"
Add-Line "Arquivos analisados com sucesso: $($Validos.Count)"
Add-Line "Arquivos com erro: $($ComErro.Count)"

# ------------------------------------------------------------
# Estatisticas de formato
# ------------------------------------------------------------

Add-Line ""
Add-Line "FORMATOS/CONTAINERS"

$Validos |
    ForEach-Object {
        $_.Info.format.format_name
    } |
    Where-Object { $_ } |
    ForEach-Object {
        $_ -split ","
    } |
    Group-Object |
    Sort-Object Count -Descending |
    ForEach-Object {
        Add-Line "$($_.Name): $($_.Count)"
    }

# ------------------------------------------------------------
# Codecs de video
# ------------------------------------------------------------

Add-Line ""
Add-Line "CODECS DE VIDEO"

$Validos |
    ForEach-Object {
        $_.Info.streams |
            Where-Object { $_.codec_type -eq "video" }
    } |
    Where-Object { $_ } |
    Group-Object codec_name |
    Sort-Object Count -Descending |
    ForEach-Object {
        Add-Line "$($_.Name): $($_.Count)"
    }

# ------------------------------------------------------------
# Codecs de audio
# ------------------------------------------------------------

Add-Line ""
Add-Line "CODECS DE AUDIO"

$Validos |
    ForEach-Object {
        $_.Info.streams |
            Where-Object { $_.codec_type -eq "audio" }
    } |
    Where-Object { $_ } |
    Group-Object codec_name |
    Sort-Object Count -Descending |
    ForEach-Object {
        Add-Line "$($_.Name): $($_.Count)"
    }

# ------------------------------------------------------------
# Resolucao
# ------------------------------------------------------------

Add-Line ""
Add-Line "RESOLUCOES"

$Validos |
    ForEach-Object {
        $_.Info.streams |
            Where-Object { $_.codec_type -eq "video" } |
            ForEach-Object {
                "$($_.width)x$($_.height)"
            }
    } |
    Group-Object |
    Sort-Object Count -Descending |
    ForEach-Object {
        Add-Line "$($_.Name): $($_.Count)"
    }

# ------------------------------------------------------------
# Frame rates
# ------------------------------------------------------------

Add-Line ""
Add-Line "FRAME RATES"

$Validos |
    ForEach-Object {

        $ArquivoAtual = $_.Arquivo.Name

        $_.Info.streams |
            Where-Object { $_.codec_type -eq "video" } |
            ForEach-Object {

                $CreationDate = ""

                if ($null -ne $_.tags) {

                    $Tag = $_.tags.PSObject.Properties |
                        Where-Object {
                            $_.Name -eq "com.apple.quicktime.creationdate"
                        } |
                        Select-Object -First 1

                    if ($null -ne $Tag) {
                        $CreationDate = [string]$Tag.Value
                    }
                }

                Add-Line "Arquivo: $ArquivoAtual | creationdate=$CreationDate | r_frame_rate=$($_.r_frame_rate) | avg_frame_rate=$($_.avg_frame_rate)"
            }
    }

# ------------------------------------------------------------
# Sample rates
# ------------------------------------------------------------

Add-Line ""
Add-Line "SAMPLE RATES DE AUDIO"

$Validos |
    ForEach-Object {
        $_.Info.streams |
            Where-Object { $_.codec_type -eq "audio" }
    } |
    Group-Object sample_rate |
    Sort-Object Count -Descending |
    ForEach-Object {
        Add-Line "$($_.Name) Hz: $($_.Count)"
    }

# ------------------------------------------------------------
# Canais
# ------------------------------------------------------------

Add-Line ""
Add-Line "CANAIS DE AUDIO"

$Validos |
    ForEach-Object {
        $_.Info.streams |
            Where-Object { $_.codec_type -eq "audio" }
    } |
    ForEach-Object {
        "channels=$($_.channels) | layout=$($_.channel_layout)"
    } |
    Group-Object |
    Sort-Object Count -Descending |
    ForEach-Object {
        Add-Line "$($_.Name): $($_.Count)"
    }

# ------------------------------------------------------------
# creation_time
# ------------------------------------------------------------

Add-Line ""
Add-Line "CREATION_TIME"

$ComCreationTime = 0
$SemCreationTime = 0

foreach ($Resultado in $Validos) {

    $Tags = $Resultado.Info.format.tags

    $Encontrou = $false

    if ($null -ne $Tags) {

        foreach ($Nome in @(
            "creation_time",
            "com.apple.quicktime.creationdate",
            "date"
        )) {

            $Propriedade = $Tags.PSObject.Properties |
                Where-Object { $_.Name -eq $Nome } |
                Select-Object -First 1

            if ($null -ne $Propriedade -and
                -not [string]::IsNullOrWhiteSpace([string]$Propriedade.Value)) {

                $Encontrou = $true
                break
            }
        }
    }

    if ($Encontrou) {
        $ComCreationTime++
    }
    else {
        $SemCreationTime++
    }
}

Add-Line "Com creation_time: $ComCreationTime"
Add-Line "Sem creation_time: $SemCreationTime"

# ------------------------------------------------------------
# Duracoes
# ------------------------------------------------------------

$Duracoes = @()

foreach ($Resultado in $Validos) {

    $Duracao = $Resultado.Info.format.duration

    if ($null -ne $Duracao) {

        $Valor = 0.0

        if ([double]::TryParse(
            [string]$Duracao,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$Valor
        )) {

            $Duracoes += $Valor
        }
    }
}

if ($Duracoes.Count -gt 0) {

    $DuracaoTotal = ($Duracoes | Measure-Object -Sum).Sum
    $DuracaoMinima = ($Duracoes | Measure-Object -Minimum).Minimum
    $DuracaoMaxima = ($Duracoes | Measure-Object -Maximum).Maximum

    Add-Line ""
    Add-Line "DURACAO"

    Add-Line ("Quantidade: {0}" -f $Duracoes.Count)
    Add-Line ("Duracao total segundos: {0:N3}" -f $DuracaoTotal)
    Add-Line ("Duracao total: {0}" -f ([TimeSpan]::FromSeconds($DuracaoTotal).ToString()))
    Add-Line ("Menor video: {0:N3} segundos" -f $DuracaoMinima)
    Add-Line ("Maior video: {0:N3} segundos" -f $DuracaoMaxima)
}

# ------------------------------------------------------------
# Tamanho total
# ------------------------------------------------------------

$TamanhoTotal = ($Arquivos | Measure-Object Length -Sum).Sum

Add-Line ""
Add-Line "TAMANHO TOTAL"
Add-Line ("Bytes: {0}" -f $TamanhoTotal)
Add-Line ("GB: {0:N3}" -f ($TamanhoTotal / 1GB))

# ------------------------------------------------------------
# Arquivos com erro
# ------------------------------------------------------------

if ($ComErro.Count -gt 0) {

    Add-Line ""
    Add-Line "ARQUIVOS COM ERRO"

    foreach ($Resultado in $ComErro) {
        Add-Line $Resultado.Arquivo.FullName
    }
}

# ------------------------------------------------------------
# Grava relatorio
# UTF-8 sem BOM para facilitar leitura
# ------------------------------------------------------------

$Utf8SemBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllLines(
    $Relatorio,
    $Linhas,
    $Utf8SemBom
)

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " RELATORIO CONCLUIDO" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Arquivos analisados: $($Resultados.Count)"
Write-Host "Relatorio:"
Write-Host $Relatorio
Write-Host ""