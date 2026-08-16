# CLAUDE.md - Histórico técnico do projeto VideoSaida

Este arquivo documenta como este pipeline foi construído com o Claude Code (agente de IA), as decisões tomadas e por quê, e os problemas técnicos já resolvidos - para que sessões futuras (humanas ou do próprio Claude) não repitam a investigação do zero.

## Objetivo do projeto

Concatenar ~255 vídeos `.mov` gravados por iPhone, guardados em `D:\VideosCurtos`, em um único arquivo `C:\VideoSaida\VideosConcatenados.mp4`, respeitando a ordem cronológica real de gravação (não a ordem de nome de arquivo nem a data de criação no Windows).

## Ambiente

- Windows, PowerShell 5.1 (`$PSVersionTable.PSVersion` = 5.1.26100) - **sem** operador `?.` (null-conditional), sem `??`, sem ternário.
- FFmpeg `2023-01-12-git-fc263f073e-essentials_build` (gyan.dev), com `--enable-libzimg` (filtro `zscale`), `--enable-nvenc`.
- GPU: NVIDIA GTX 1050 (Pascal).

## Linha do tempo das tentativas

1. **`ffmpeg -f concat -c copy`** → vídeo final saiu acelerado e com áudio dessincronizado. Causa: VFR real nos clipes (confirmado depois via `r_frame_rate` != `avg_frame_rate` no ffprobe) e diferenças de timebase entre arquivos - stream copy não é seguro nesse cenário.
2. **`ffmpeg -f concat` + recodificação com `h264_nvenc`, sem normalizar antes** (`concatenarvideos.ps1`, mantido no repo como histórico) → erros de decodificação de áudio (`Rematrix is needed between 43 channels and stereo`, `channel element 3.9 is not allocated`, etc.). Causa raiz identificada depois: mistura sistemática de `pcm_s16le` mono (sem `channel_layout`) e `aac` estéreo/mono entre os 255 arquivos - o filtergraph de áudio não consegue resolver a mixagem automaticamente quando os inputs mudam de layout no meio do grafo.
3. **Decisão**: parar de tentar ajustar parâmetros no escuro e primeiro extrair todos os metadados técnicos dos 255 arquivos via `ffprobe` (`GerarInfoVideos.ps1` → `InformacoesVideos.txt`, ~123k linhas / 5MB) antes de desenhar a estratégia final.

## Achados da análise de metadados (`InformacoesVideos.txt`)

Estes achados **não estavam previstos** no problema original e só apareceram depois de ler o relatório completo:

- **Campo de data correto**: `com.apple.quicktime.creationdate` (FORMAT TAGS) é a hora **local** e é o que aparece como "Mídia criada" no Windows/iPhone. Verificado com o exemplo do usuário: `IMG_3023.MOV` → `com.apple.quicktime.creationdate: 2023-03-13T15:35:35-0300`, batendo exatamente com "13/03/2023 15:35". O campo `creation_time` (também em FORMAT TAGS e replicado em cada stream) é o mesmo instante em **UTC** (`2023-03-13T18:35:36.000000Z`) - serve para ordenar (é monotônico), mas não deve ser usado para exibir/comparar com o que o usuário vê no Windows.
- Vídeo: 100% HEVC (255/255).
- Áudio: `pcm_s16le` mono sem `channel_layout` (128 arquivos, `codec_tag_string=lpcm`) vs `aac` estéreo (116) / mono (4) (120 arquivos); 7 arquivos sem stream de áudio algum. Sample rate uniforme em 44100Hz onde há áudio.
- Cor: `bt709` SDR (25 arquivos), `bt2020nc`+`arib-std-b67` HDR/HLG (102 arquivos, alguns com DOVI profile 8 - Dolby Vision), `smpte170m`/`smpte432` (128 arquivos, WCG mas transfer já `bt709`).
- Pixel format: `yuv420p` (8-bit) e `yuv420p10le` (10-bit) misturados (correlaciona com os HDR).
- Orientação: ~208 arquivos com `rotation: -90` (retrato), ~37 sem metadado de rotação (paisagem), poucos com `-180`/`90`. Resoluções brutas (antes de aplicar rotação): `1920x1080` (224) e `1920x1440` (31).
- Duração total real: **apenas 573s (~9m33s)** para os 255 arquivos - são clipes curtos (0,048s a 4,9s, média 2,25s), consistentes com vídeos-companheiro de Live Photo, não gravações longas manuais. Isso importa porque significa que o processamento total é rápido mesmo com filtros pesados (tonemap) - performance nunca foi o gargalo real.

## Estratégia final adotada

Duas etapas, para nunca depender de stream copy entre arquivos heterogêneos, mas também nunca recodificar mais de uma vez cada clipe:

1. **Normalizar cada clipe individualmente** para um formato-alvo idêntico (única recodificação), usando `hevc_nvenc`.
2. **Concatenar os já-normalizados com `-c copy`** (instantâneo, sem perda adicional).

Decisões tomadas em conjunto com o usuário (perguntadas explicitamente via pergunta de múltipla escolha, pois são decisões de gosto/visual, não técnicas):

- **Canvas final**: retrato `1440x1920` com letterbox preto (sem cortar imagem), pois ~82% dos clipes já são retrato nessa proporção ou próxima. Alternativas descartadas: quadrado `1920x1920`, paisagem `1920x1080`.
- **Codec final**: HEVC (`hevc_nvenc`) em vez de H.264, pelo tamanho de arquivo menor a mesma qualidade (compressão ~30-40% melhor), já que a fonte também era HEVC.

Parâmetros técnicos decididos sem precisar perguntar ao usuário (escolhas de engenharia, validadas por teste real antes de rodar nos 255 arquivos):

- `fps=60` (CFR) - a maioria dos clipes já declarava frame rates próximos de 60fps; forçar CFR elimina o VFR sem perda perceptível (frames duplicados custam pouquíssimo bitrate em HEVC).
- Tone-mapping HDR→SDR **condicional por arquivo** (branch em PowerShell no `color_transfer` lido via `ffprobe -show_streams`), não aplicado a todos os arquivos: evita gastar o pipeline `zscale=linear→tonemap→zscale=bt709` em arquivos que já são SDR.
  - Pipeline HDR: `zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p` (receita padrão da wiki do ffmpeg para HDR→SDR).
  - Pipeline SDR/WCG: `zscale=t=bt709:m=bt709:p=bt709:r=tv,format=yuv420p` (só corrige primaries/matrix, sem linearizar).
- Áudio: arquivos sem stream de áudio recebem uma trilha de silêncio via `-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100` + `-shortest`, para manter os streams consistentes entre todos os clipes normalizados (senão o concat demuxer final quebraria por streams inconsistentes).

## Problemas técnicos resolvidos durante a implementação (importante para não repetir)

1. **`-temporal_aq` no `hevc_nvenc` falha na GTX 1050** com `Temporal AQ not supported` / `No capable devices found`. Pascal não suporta esse recurso no encoder HEVC. **Não usar** `-temporal_aq` nesta GPU (funciona em `-spatial_aq`).
2. **Preset `p6`/`p7` do `hevc_nvenc` tenta usar B-frames como referência por padrão**, o que também falha na GTX 1050 (`B frames as references are not supported` / `No capable devices found`). Correção: adicionar explicitamente `-b_ref_mode disabled`.
3. **CQ irrestrito (`-rc vbr -cq 19 -b:v 0`) gera arquivos ~30-40% maiores que os originais** nesta coleção - o `hevc_nvenc` da GTX 1050 é menos eficiente em bits que o encoder de hardware da Apple para o mesmo nível de qualidade percebida. Testado e resolvido usando **VBR com teto de bitrate explícito** em vez de CQ puro: `-rc vbr -b:v 15M -maxrate 22M -bufsize 30M -spatial_aq 1 -aq-strength 8`. Em 3 amostras de teste (SDR, HDR, sem áudio) o resultado final ficou **menor** que a soma dos originais. No lote completo (255 arquivos), o resultado final foi 1,06GB contra 999MB de original (+8,7%), dentro do aceitável.
4. **Bug do PowerShell 5.1 com `2>&1 | Out-File` em comandos nativos**: redirecionar stderr de um `.exe` externo (ffmpeg) via `2>&1` dentro de um pipeline embrulha cada linha em um `ErrorRecord` (`NativeCommandError`), e com `$ErrorActionPreference = "Stop"` isso aborta o script inteiro na primeira chamada ao ffmpeg (mesmo que o ffmpeg termine com exit code 0 - a saída de progresso normal do ffmpeg já vai para stderr). Correção: **nunca usar `2>&1` com comandos nativos cujo stderr você quer só logar**; usar redirecionamento direto de arquivo (`2>> arquivo.txt`, sem o `&1`) e evitar `$ErrorActionPreference = "Stop"` como preferência global quando o script já tem seu próprio controle de erro via `$LASTEXITCODE`/`Test-Path`.

## Estado atual

- `NormalizarEConcatenar.ps1` rodou com sucesso nos 255 arquivos: 255/255 normalizados, concatenação final ok.
- `VideosConcatenados.mp4`: 1,06GB, ~9m34,7s, deriva de áudio/vídeo de ~30ms no arquivo inteiro (verificado via `ffprobe` comparando `duration` do stream de vídeo e de áudio).
- Verificação visual: frame extraído do clipe #12 (`IMG_3023.MOV`, o exemplo original do usuário) confirmou orientação e enquadramento corretos, sem distorção.
- `ordem_videos.txt` confirma a correção do campo de data: `0012 | 2023-03-13 15:35:35 -03:00 | D:\VideosCurtos\IMG_3023.MOV`.

## Se for preciso continuar/estender este projeto

- Reexecutar `GerarInfoVideos.ps1` se novos vídeos forem adicionados a `D:\VideosCurtos`, antes de rodar `NormalizarEConcatenar.ps1` de novo.
- `NormalizarEConcatenar.ps1 -Reprocessar` força renormalizar tudo; sem essa flag, arquivos já presentes em `Normalizados\` são reaproveitados (permite retomar após interrupção).
- Se o tamanho final precisar ser menor, reduzir `$BitrateAlvo`/`$BitrateMax` no início do script (atualmente `15M`/`22M`).
- Se quiser manter HDR real na saída (em vez de converter tudo para SDR), seria necessário mudar a estratégia de canvas/pixel format para 10-bit uniforme e reconsiderar o pipeline de tonemap - não foi pedido pelo usuário nesta versão.
