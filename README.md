# VideoSaida

Scripts em PowerShell + FFmpeg para analisar e concatenar, em ordem cronológica de gravação, uma coleção de vídeos `.mov`/`.mp4`/`.m4v` gravados por iPhone (armazenados em `D:\VideosCurtos`), gerando um único arquivo final em `C:\VideoSaida\VideosConcatenados.mp4`.

## Por que isso não é um `ffmpeg -f concat -c copy` simples

Vídeos do iPhone acumulados ao longo do tempo (diferentes modelos, versões de iOS, modos de captura) raramente são homogêneos entre si. Nesta coleção (255 arquivos), foi confirmado por análise de metadados que os clipes misturam:

- **Áudio**: `pcm_s16le` mono sem `channel_layout` vs `aac` estéreo/mono, e 7 arquivos sem áudio algum.
- **Espaço de cor**: SDR (`bt709`), HDR/HLG (`bt2020nc` + `arib-std-b67`, alguns com Dolby Vision profile 8) e WCG (`smpte170m`/`smpte432`).
- **Profundidade de bit**: 8-bit (`yuv420p`) e 10-bit (`yuv420p10le`).
- **Orientação/resolução**: retrato e paisagem misturados (rotação -90/90/-180 via display matrix), resoluções brutas `1920x1080` e `1920x1440`.
- **Frame rate**: variável (VFR) - `r_frame_rate` e `avg_frame_rate` divergem no mesmo arquivo.

Concatenar esses streams diretamente (com ou sem recodificação ingênua) produz dessincronia de áudio/vídeo ou falhas de decodificação (erros de "rematrix" entre layouts de canal incompatíveis). A solução é normalizar cada clipe para um formato comum antes de concatenar.

## Scripts

### `GerarInfoVideos.ps1`
Varre `D:\VideosCurtos` (recursivo, extensões `.mov`/`.mp4`/`.m4v`) e roda `ffprobe` em cada arquivo, gerando `InformacoesVideos.txt`: um relatório técnico completo (container, todos os streams, tags de metadado, cores, áudio, resumo estatístico agregado). É o ponto de partida para qualquer decisão de normalização - deve ser reexecutado se novos vídeos forem adicionados a `D:\VideosCurtos` antes de rodar o pipeline de concatenação.

### `NormalizarEConcatenar.ps1` (script principal, produção)
Pipeline de duas etapas:

1. **Normalização** (uma recodificação por clipe, GPU NVENC): para cada vídeo, na ordem cronológica correta, aplica um filtro único que resolve todas as inconsistências acima:
   - `com.apple.quicktime.creationdate` (hora local do iPhone) como campo de ordenação, com fallback para `creation_time` (UTC) e depois `LastWriteTime` do arquivo.
   - Tone-mapping condicional HDR (HLG/PQ) → SDR `bt709` via `zscale`/`tonemap`; correção de gamut para fontes WCG.
   - `scale` + `pad` para uma moldura comum retrato `1440x1920`, sem cortar imagem (letterbox preto).
   - `fps=60` (CFR) para eliminar VFR.
   - Áudio normalizado para AAC estéreo 44.1kHz; arquivos sem áudio recebem uma trilha silenciosa (`anullsrc`) para manter os streams consistentes.
   - Codificação de vídeo em `hevc_nvenc` (GTX 1050) em VBR com teto de bitrate (evita CQ irrestrito, que gera arquivos maiores que o necessário).
   - Saída intermediária em `Normalizados\0001.mp4`, `0002.mp4`, ... (numeração = ordem cronológica).
2. **Concatenação**: como os arquivos normalizados já são idênticos em codec/resolução/fps/áudio, a concatenação final usa `-c copy` (instantânea, sem perda adicional) via `ffmpeg -f concat`.

Gera também:
- `ordem_videos.txt` - relatório da ordem final (número, data/hora local, caminho original, e sinalizadores de tratamento especial: HDR→SDR, sem áudio, fonte de data alternativa).
- `log_normalizacao.txt` - log bruto do ffmpeg de cada normalização (útil para depurar falhas pontuais).

Suporta `-Reprocessar` para forçar a normalização novamente mesmo se o arquivo intermediário já existir (por padrão, reexecuções pulam clipes já normalizados, permitindo retomar após interrupções).

Os arquivos originais em `D:\VideosCurtos` nunca são lidos em modo de escrita, modificados ou apagados.

### `concatenarvideos.ps1` (obsoleto - mantido como histórico)
Primeira tentativa: concatenação direta com `h264_nvenc` sem normalização prévia dos clipes. Falhava com erros de rematrix de áudio por causa da mistura de codecs/layouts de áudio descrita acima. Mantido no repositório apenas como registro do que foi tentado; **não usar** - use `NormalizarEConcatenar.ps1`.

## Requisitos

- Windows PowerShell 5.1 (não usa sintaxe exclusiva do PowerShell 7+, como `?.`)
- `ffmpeg` e `ffprobe` no PATH, com suporte a `hevc_nvenc`, `zscale` (libzimg) e `tonemap`
- GPU NVIDIA com NVENC (testado em GTX 1050 / Pascal - **não suporta `-temporal_aq`** no encoder HEVC, ver `CLAUDE.md`)

## Uso

```powershell
# 1) Gerar relatório de metadados (opcional se InformacoesVideos.txt já existe e nada mudou em D:\VideosCurtos)
.\GerarInfoVideos.ps1

# 2) Normalizar e concatenar
.\NormalizarEConcatenar.ps1

# Forçar renormalização de tudo, mesmo que Normalizados\ já exista
.\NormalizarEConcatenar.ps1 -Reprocessar
```

## Saídas geradas

| Arquivo/pasta | Descrição | No git? |
|---|---|---|
| `VideosConcatenados.mp4` | Vídeo final | Não (`.gitignore`, é binário grande) |
| `Normalizados\` | 255 clipes intermediários já normalizados | Não (`.gitignore`) |
| `ordem_videos.txt` | Relatório da ordem cronológica final | Sim |
| `InformacoesVideos.txt` | Relatório técnico bruto do `ffprobe` | Sim |
| `execucao_log.txt` / `log_normalizacao.txt` | Logs de execução | Sim |

Veja `CLAUDE.md` para o histórico completo de decisões técnicas, testes e problemas resolvidos durante a construção deste pipeline.
