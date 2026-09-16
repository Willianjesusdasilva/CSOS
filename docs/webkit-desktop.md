# Desktop via WebKit: contrato e evidências

Requisito confirmado em 2026-09-08: HTML + CSS + JavaScript executados por
WebKit no userspace do CSOS. O resultado deve seguir `desktop.png`, preservado
como referência, e aceitar mouse/teclado reais no QEMU.

## Arquitetura alvo

- HTML: estrutura das janelas, dock, launcher, menus e widgets.
- CSS: layout responsivo, tipografia, wallpaper, ícones e glass.
- JavaScript: foco, arraste, resize, menus, atalhos e estado da interface.
- WebKit/WebCore/JavaScriptCore: DOM, CSS, rasterização e execução de scripts.
- Backend CSOS prioritariamente Zig: apresentação de superfícies, eventos e
  serviços privilegiados por IPC validado. JavaScript não recebe syscalls
  arbitrárias nem acesso irrestrito ao filesystem.
- Compositor/kernel: isolamento, recursos e display; não duplicar o desktop
  desenhando painéis nativos embaixo de uma página parcial.

WPE é a base de investigação porque separa a entrega dos frames e entrada de
eventos de um toolkit desktop. Isso não torna o CSOS uma plataforma suportada
automaticamente: é necessário portar suas dependências e o backend.

## Auditoria inicial do repositório

- `userspace/ui_runtime.zig` abre e fecha recursos, emite mensagens de IPC e
  um pixel sintético. Não lê/renderiza HTML nem instancia WebKit.
- `graphics/sdl.zig` desenha o desktop fixamente com `drawReferenceDesktop`.
- `graphics/html.zig` não é WebCore; seu parser limitado não atende ao contrato.
- Há trabalhos prévios de musl/ELF/TLS, mas não há evidência de que suportem
  JavaScriptCore, as dependências do WPE ou seus processos/threads.
- O renderer CSS próprio iniciado nesta mudança foi removido antes da
  integração porque contradizia o requisito explícito de WebKit.

## Ordem de implementação e critérios

1. Fixar uma versão upstream e inventariar dependências reais de build e
   runtime; auditar ABI C/C++, TLS, threads, temporizadores, memória virtual,
   sincronização e IPC contra o kernel existente. Não inferir suporte só pela
   presença do número de uma syscall.
2. Compilar e executar JavaScriptCore no CSOS com um script e saída verificável;
   começar sem JIT se necessário. Teste no host é apenas pré-validação.
3. Portar WebCore/WPE e seu caminho de renderização em software. Validar uma
   página local com CSS, fontes, imagem e alteração de DOM por JavaScript.
4. Conectar frames, stride, resize, ownership de buffers e acknowledgments ao
   compositor; encaminhar mouse, teclado, foco, wheel e caracteres Unicode.
5. Implementar a interface de referência em HTML/CSS/JS com serviços reais.
   Estado desconhecido deve aparecer indisponível; não inventar percentuais,
   downloads, músicas em reprodução ou disponibilidade de Steam.
6. Validar capturas em 1536x1024 e na resolução do QEMU; clicar launcher,
   abrir aplicação, arrastar/redimensionar janela, alternar foco e digitar.
   Encerrar cada QEMU de validação após capturar suas evidências.

GPU física permanece em standby. Não trocar o kernel por Linux silenciosamente
para afirmar que o WebKit foi portado. Não usar uma imagem do desktop como UI.
Jinja pode preparar HTML antes da carga, mas não substitui o motor WebKit.

### Estado atual do backend WPE

O launcher Zig já carrega o ELF WPE/WebKit, inicializa o shared-memory backend,
TLS e `webkit_web_view_backend_new`. Após remover a criação descartada de um
contexto explícito, o smoke QEMU alcança `WebKit view begin`; o bloqueio agora
ocorre dentro de `webkit_web_view_new()` antes de `WebKit view ready`. O
diagnóstico temporário mostrou a terceira thread sendo ativada e retornando ao
thread principal. O processo filho chega a tocar uma reserva `MAP_NORESERVE`
fora da arena eager; o kernel agora a trata como reserva virtual e corrige o
frame de erro de page fault para permitir o commit lazy da página. Ainda não há
evidência de `load_html`, entrega de frame ao compositor ou entrada DOM: o
smoke permanece antes de `WebKit view ready`, portanto o próximo diagnóstico é
o caminho de entrega da exceção/retomada do processo filho.

O código upstream confirma que a construção da primeira página usa o
`ProcessLauncher` WPE/GLib: cria `socketpair(AF_UNIX, SOCK_SEQPACKET)`, inicia
um WebProcess via `wpe_process_provider`/`g_subprocess`, e aguarda o processo
auxiliar através do socket IPC. Portanto, o próximo gate não é apenas
preempção de threads: exige processo filho, `execve`/loader independente,
ownership de descritores e lifecycle de PID no kernel.

Atualização (2026-09-16): a comparação com o `__clone` real da musl mostrou
que o callback de `posix_spawn` entra em `0x88210` com RDI correto e RFLAGS
com IF habilitado. O frame do filho estava, porém, um word acima do stack
pointer fornecido pela musl; isso quebrava o alinhamento SysV de 16 bytes no
prólogo SSE do WebKit. O commit `0917e9c8` preserva `child_stack` ao entrar
diretamente no callback. A nova evidência confirma que o filho já executa
`close` e a sequência inicial de `rt_sigaction`; ainda não chega a
`execve`/`WebKit view ready`, portanto o gate WPE permanece aberto e o próximo
diagnóstico é o progresso dessa inicialização/lifecycle, não um mock de frame.

Também foi corrigido o limite de `rt_sigaction`: a tabela agora reserva 65
entradas, mantendo o índice zero inutilizado e aceitando corretamente o sinal
Linux 64. O ajuste passou a suíte nativa; a execução WPE ainda precisa
confirmar o avanço além da inicialização de sinais.

Em uma execução longa subsequente (`zig-out/smoke-a035e9ba39c94a589ca84173d96935de.serial.log`),
o processo filho completou o loader e emitiu `CSOS WPE WebProcess scheduled`.
Isso fecha a criação/execução do subprocesso como evidência intermitente, mas
o novo image entry ainda não emite `WPE shm ready`/`WebKit view ready`; a
repetição curta continua necessária para tornar o lifecycle determinístico.

Diagnóstico posterior (`zig-out/smoke-ab480c0bb1c9446bbfcc973646929211.serial.log`)
confirmou que, após o marcador de scheduling, o loop do loader seleciona o
workspace filho e ativa seu CR3 (`CSOS exec child loop entry` e `CSOS exec child
address space active`). O entry observado foi `0x70000012ac` e a stack
`0x900001f5c0`; nenhum syscall do novo image foi observado antes do timeout.
O bloqueio foi assim reduzido à entrada do interpretador ELF/primeiro código do
WebProcess, não à seleção de workspace ou ao `execve`.

Uma captura posterior verificou ainda que o root CR3 filho (`29511680`) e a
página do entry possuem mapeamento executável (`exec=1`) antes do `iretq`.
Mesmo assim nenhum syscall do interpretador chega ao dispatcher, indicando que
a próxima investigação deve comparar o frame de entrada (`iretq`, CS/SS e
RSP) com o contrato de inicialização ELF, antes de mexer em syscalls de IPC.

O conteúdo do stack também foi auditado em QEMU: `argc=3`, auxv `0x6002`
aponta para uma estrutura `MuslBootstrap` válida no próprio stack. Assim, o
interpretador recebe seus argumentos privados; o ponto restante é a execução
do bootstrap TLS/construtores (antes do retorno ao dispatcher), não a montagem
do auxv.

## Primeiro gate de runtime: evidência QEMU (2026-09-08)

Foi acrescentado um executável **Zig**, ligado estaticamente à musl, que chama
`pthread_create`, executa código na thread filha, verifica isolamento TLS e
chama `pthread_join`. Ele não contém JavaScriptCore e não é uma emulação de
pthread: chama as funções reais da libc. Sucesso só pode ser emitido depois
de executar e juntar a filha com TLS preservado.

```powershell
.\tools\build-webkit-runtime-probe.ps1
.\.tools\zig-x86_64-windows-0.16.0\zig.exe build run -Dwebkit-runtime-probe=zig-out/webkit-runtime-probe -- -ResetDisk -SmokeTestSeconds 40 -ExpectSerial 'CSOS WebKit prerequisite PASS:'
```

**Resultado inicial: FAIL, `pthread_create errno=11`.** A execução de diagnóstico
esperou explicitamente o marcador FAIL e encerrou QEMU. O exit 0 desse runner
significa apenas que observou a falha esperada, não que o gate passou. O programa
retornou 21 e o kernel registrou `ProcessFailed`.
Log local: `zig-out/smoke-e66add5667ae47a8a04e80c08d247489.serial.log`.

A inspeção inicial do dispatcher confirmou ausência de `clone` (56) e `clone3` (435).
O `futex` inicial nunca colocava um waiter para dormir; `gettid` era fixo em 1.
O scheduler de threads do kernel não basta: `process.runImage` tem contexto
ativo e bookkeeping globais. A implementação abaixo adiciona threads dentro
do mesmo processo; não representa suporte a múltiplos processos concorrentes.

### Avanço funcional: pthread/mutex/condition/TLS

Implementados o clone realmente observado (`0x7d0f00`), contextos SYSRET,
stack individual, FS/TLS, estado FPU, TID, clear_child_tid, saída individual
e escalonamento cooperativo dentro do mesmo address space. VM e descritores
são compartilhados por esse subset de clone. FUTEX_WAIT/WAKE (inclusive
PRIVATE) bloqueiam e acordam tasks; não reenviam WAIT em busy loop.

A musl solicitou 8.663.040 bytes de stack/TLS e falhava antes de clone porque
o mmap arena antigo tinha 4 MiB. O arena mmap agora tem 64 MiB, separado de brk.
É uma reserva física fixa de bootstrap, não memória virtual sob demanda.

Validação real em QEMU, log
`zig-out/smoke-977ebc1c9ac142a3931d25d80941d979.serial.log`:

- pthread_create e pthread_join com execução da filha passaram;
- três workers, mutex e condition variable produziram contador 300;
- cada worker manteve TLS distinto após trocas de contexto;
- o kernel registrou **209 bloqueios e 209 despertares**;
- saída de filha não encerrou o processo; o boot continuou depois do probe;
- QEMU foi encerrado pelo runner; `zig build test` passou.

Para exigir também o gate de bloqueio no kernel, usar
`-ExpectSerial 'CSOS WebKit futex transitions PASS:'` no comando acima.

Limites explícitos: até 16 contextos, escalonamento cooperativo, sem clone de
processo, sem timers de futex, sem preempção userspace e sem recuperação de
robust mutex pelo kernel. Uma situação sem tasks runnable termina com erro
de deadlock; ainda não há espera por produtores externos. O port WebKit não
está concluído por esse avanço. Próximos gates: GLib mínimo e event loop,
implementando as capacidades adicionais que sua execução exigir.

### Capability adicional validada: eventfd/poll

A GLib usa `eventfd` para acordar o loop quando disponível. O VFS agora possui
descritor eventfd com contador de 64 bits, leitura consumidora e escrita
acumulativa; `eventfd2` aceita somente `EFD_CLOEXEC`/`EFD_NONBLOCK`. `poll`
observa a prontidão do contador e não fabrica leitura permanente.

O mesmo binário musl validou no QEMU: `eventfd(0)`, `write(1)`, `poll(POLLIN)`
e `read()==1`, emitindo `CSOS WebKit prerequisite PASS: eventfd/poll` antes
dos testes de threads. A evidência está em
`zig-out/smoke-77ee2b5b060242629416990a2cf84fe1.serial.log`.

Atualização (2026-09-15): o probe upstream `glib-runtime-probe` foi executado
dentro do CSOS no QEMU e completou `GMainLoop` com `g_timeout_add`, emitindo
`CSOS upstream GLib event-loop/timer PASS`. O teste não é um loop substituto:
usa GLib compilada para o target musl e confirma o event loop/timer real. O
próximo gate permanece o processo WPE/WebKit e seu transporte IPC.

### Dependência de build destravada: PCRE2

O primeiro erro terminal do Meson foi `libpcre2-8 >= 10.32` ausente. PCRE2
10.44 foi baixado do release upstream e compilado para `x86_64-linux-musl`
com CMake/Ninja e Zig, com Unicode habilitado, JIT desabilitado e apenas a
biblioteca estática de 8 bits. `tools/build-pcre2-linux.ps1` reproduz a
configuração e instala header, archive e pkg-config no sysroot CSOS. O erro
seguinte ainda é libffi; GLib não foi declarado compilado.

Libffi 3.2.9999 também foi compilada para o mesmo target com as rotinas x86_64
de ABI e staged no sysroot. `tools/build-libffi-linux.ps1` reproduz esse passo.
Com PCRE2 e libffi presentes, a próxima configuração do GLib deve chegar ao
build da biblioteca; ainda será necessário executar o probe GLib dentro do
QEMU antes de fechar os gates de event loop.

Upstream fixado para investigação: **WPE WebKit 2.52.6**, commit
`3bcefb149bd7e5645d18c3f0b9abd515b274649f` (tag anotada resolvida).
`tools/fetch-webkit.ps1` prepara esse checkout sem descartar mudanças locais.
A compilação real do engine foi iniciada no diretório `zig-out/webkit-linux6`;
a execução ainda não foi realizada porque o link final do WPE/WebKit depende da
conclusão de JavaScriptCore, WebCore e das bibliotecas WPE.

## WPE platform bootstrap

`tools/build-libwpe-linux.ps1` compila o `libwpe` upstream 1.16.3 para o
sysroot musl com Zig. O gate confirmou os headers EGL/KHR exigidos pelo
backend WPE. Wayland 1.23.1 também foi compilado para o mesmo target, com o
scanner nativo separado em `tools/wayland-native.ini`.

O `wpebackend-fdo` upstream 1.16.1, commit `fc6f3d428962b34e1937aaa6bf66bcba92243da0`,
agora compila e linka como `libWPEBackend-fdo-1.0.so.1.10.2` usando os
archives Wayland/GLib/Epoxy do sysroot. O passo é reproduzível por
`tools/build-wpebackend-fdo-linux.ps1`; o artefato ainda não é uma prova de
runtime no CSOS e aguarda ser ligado ao processo WPE/WebKit e validado no
compositor real.

### Dependências WPE/WebKit destravadas (cross build)

O sysroot agora contém builds estáticos verificáveis de ICU 76.1, HarfBuzz
10.4.0, libjpeg-turbo 3.0.4, Epoxy 1.5.10, libgcrypt 1.11.0,
libgpg-error 1.50, libnghttp2 1.64.0, libpsl 0.21.5, SQLite 3.49.1 e
libsoup 3.6.5, todos compilados para `x86_64-linux-musl` com Zig. A
configuração CMake do WPE WebKit 2.52.6 já encontra esses componentes. Depois
foram adicionados libtasn1 4.19.0 e xkbcommon 1.7.0; o CMake também passou por
libxml2 2.13.8, libpng 1.6.43 e libwebp 1.4.0 (incluindo demux). O gate atual
é a ferramenta host `glib-compile-resources`, usada apenas na geração do
build. Os diretórios `.tools` e `zig-out` são artefatos locais ignorados;
scripts de build devem manter as mesmas opções e o sysroot para permitir
reprodução limpa. Cairo 1.18.0 também foi compilado com Pixman e PNG; o CMake
já o aceita. Fontconfig 2.15.0, FreeType 2.13.3 e Expat 2.6.4 agora também
estão compilados e staged estaticamente. O gperf host (3.1) e unifdef host
foram preparados para as etapas de geração. Com esses componentes, a
configuração CMake do WPE WebKit fecha e enumera 6.426 unidades de compilação,
incluindo JavaScriptCore, WebCore e WebKit.

O link final do `libWPEWebKit-2.0.so.1.9.10` foi validado no host com o backend
real, sem o objeto `wpe-loader-link-stub.o`. `tools/link-webkit-wpebackend.ps1`
recria o response file de link a partir do CMake e adiciona o backend FDO e as
dependências estáticas restantes; o símbolo `_wpe_loader_interface` fica
resolvido pelo `libWPEBackend-fdo` real. Isso ainda é uma validação de build/link
cross no host, não execução no CSOS. O próximo gate é iniciar o processo WPE no
CSOS e conectar display, mailbox/IPC e input ao compositor.

### Launcher WPE real no CSOS

`userspace/webkit_launcher.zig` agora é compilado em Zig contra o WebKit e o
backend FDO reais. `build.zig` e `tools/make-fat16.ps1` empacotam o launcher,
`libWPEWebKit-2.0.so.1.9.10` e `libWPEBackend-fdo-1.0.so.1.10.2` no FAT do
QEMU. O loader ELF aceita esses aliases, mapeia o engine grande e trata
relocations que atravessam páginas. O smoke alcança `FAT WebKit entry ready` e
`Linux PT_INTERP loader ready`; o backend FDO é inicializado em modo SHM para
QEMU. A busca de clusters FAT foi otimizada para varrer cada setor da FAT uma
vez, evitando que a imagem grande do WebKit torne o seed dos diretórios UI
quadraticamente lento. Com isso o smoke agora alcança `WPE shm ready`,
`WebKit TLS ready`, `WebKit backend ready` e `WebKit view begin`.
O retorno `CSOS WPE WebKit launcher returned` ainda não foi observado: o bloqueio
agora avançou além de `webkit_web_view_new()` até a criação de subprocesso GIO:
 o smoke falha em `g_subprocess` porque o processo auxiliar ainda não completa
 seu ciclo `clone`/`execve` no loader CSOS. `WebKit view ready` e o loop GLib
 continuam pendentes.

### Avanço incremental do subprocesso WPE (2026-09-14)

O dispatcher agora aceita `F_DUPFD_CLOEXEC` para os descritores locais usados
por WPE e reconhece o formato musl `clone(CLONE_VM|CLONE_VFORK|SIGCHLD)`
(`0x4111`), incluindo o callback e a stack ABI x86-64. O smoke QEMU confirma
que o GIO passa do assertion inicial e chega ao clone `16657`. O callback ainda
não completa a retomada `execve`/saída no workspace filho; portanto este é um
avanço de ABI, não a validação final do WebProcess.

O loader agora também aceita os artefatos reais `WPEWebProcess` e
`WPENetworkProcess` através de `-Dwebkit-web-process` e
`-Dwebkit-network-process`, e copia a página do argumento do `vfork` para o
workspace filho. Com os binários de `C:/w/zig-out/webkit-linux6/bin`, o erro
`ExecImageNotFound` deixa de ocorrer; o smoke ainda aguarda o carregamento e o
handshake do processo auxiliar.
HTML/CSS/JavaScript no CSOS continua um gate aberto, não uma validação final.

O carregamento do processo filho agora preserva o workspace e o frame de
execução em vez de manter um loader aninhado síncrono. O loop principal
retoma o WPEWebProcess como tarefa cooperativa ao lado do pai; o smoke QEMU
confirma CSOS WPE WebProcess scheduled e syscalls do auxiliar após
Linux PT_INTERP loader ready. O próximo gate é o handshake IPC completar e
produzir WebKit view ready; a página HTML ainda não foi entregue ao
compositor.

### Diagnóstico do scheduler do WebProcess (2026-09-14)

Uma execução instrumentada e depois limpa confirmou que o `clone` interno do
launcher (`0x7d0f00`) cria e alterna threads normalmente. Em seguida, o
`clone(CLONE_VM|CLONE_VFORK|SIGCHLD)` do WebProcess (`16657`) também cria a task
filha e ela é selecionada pelo scheduler. Assim, o bloqueio atual está depois
da entrada da task filha — no retorno `execve`, na entrega de page fault ou no
handshake IPC — e não na criação/seleção cooperativa do processo.

O trace de exceções do QEMU também é determinístico: após o filho imprimir
`Linux PT_INTERP loader ready`, ele acessa `CR2=0x000000e000000010` com erro
de page fault de escrita em CPL3; a entrega do vetor 14 falha imediatamente e
vira `#DF`/triple fault, sem alcançar `page_fault_dispatch`. A próxima
correção deve garantir a entrada de exceção e a pilha RSP0/IST no
address-space filho antes de tentar mascarar a falta.

Leitura adicional no runtime mostrou que a entrada 14 já está zerada antes de
`cloneProcessWorkspace` começar, embora `idt.install()` a inicialize com um
gate válido. A mesma página física continua mapeada no CR3 filho; o problema
é, portanto, corrupção/reuso da memória da IDT durante a inicialização do
kernel (antes do WebProcess), e não uma cópia incorreta do page table do filho.

### Bloqueio atual do artefato WebProcess

Em 2026-09-12, uma tentativa reproduzível de construir o alvo
`WPEWebProcess` (`ninja -C zig-out/webkit-linux6 WPEWebProcess -j4`) avançou de
`[1/1442]` para `[4/1408]`, mas ficou sem novo output por mais de três minutos
em `Generate bindings (WebCoreBindings)`, com Perl host e o pré-processador
`zig -E` ativos. Só foram emitidos avisos de locale do Perl; não há
`bin/WPEWebProcess` produzido. A execução foi interrompida e os processos de
build foram finalizados, sem QEMU aberto. Esse é um bloqueio de ferramenta ou
geração do cross-build, distinto do bloqueio de `webkit_web_view_new()` no
runtime CSOS.

### Avanço estrutural do processo WPE (2026-09-15)

O launcher agora completa o `clone(CLONE_VM|CLONE_VFORK|SIGCHLD)`, entra no
callback musl e executa o `execve` real de `WPENetworkProcess` no workspace
filho. O loader libera explicitamente o parent do `vfork` após o novo image
ser instalado; slices dentro das reservas `MAP_NORESERVE` são validados pelo
CR3 do workspace; e eventfds clonados compartilham o contador subjacente por
geração, mantendo `close` local à tabela de cada workspace. O smoke QEMU
confirma o carregamento do processo de rede e o retorno do launcher ao
scheduler, sem os `EFAULT` de `poll` observados anteriormente.

`WebKit view ready` ainda não foi observado. O bloqueio restante é o
handshake IPC entre o launcher e os processos WPE depois dessa retomada; este
avanço não deve ser contado como HTML/CSS/JavaScript entregue ao compositor.

O scheduler também passou a ceder no caminho `FUTEX_WAIT` que retorna
`EAGAIN`, evitando starvation quando um processo WPE gira em `ppoll` ou espera
uma condição já alterada. O smoke seguinte confirmou a criação do segundo
processo WPE e o primeiro `mmap` do WebProcess. Logo depois, `clone(0x7d0f00)`
cria a thread pthread de inicialização, mas ela não chega ao primeiro syscall
dentro do timeout; o bloqueio está na inicialização/retorno cooperativo dessa
thread, antes do handshake IPC.

Correção incremental em 15/09/2026: o criador agora permanece ativo até
publicar o registro de início e executar `FUTEX_WAKE`; só então a thread
deferred é escalonada. O smoke QEMU passou a mostrar um segundo
`Linux PT_INTERP loader ready` após o `clone` do WebProcess, evidência de que a
thread atravessou parte adicional do bootstrap. `WebKit view ready` ainda não
foi produzido.

Correção adicional: após `execve`, o scheduler mantém o processo substituto
como contexto ativo em vez de selecionar imediatamente o launcher pai. O
smoke seguinte confirmou `Linux PT_INTERP loader ready` logo após
`CSOS WPE WebProcess scheduled`; o próximo bloqueio permanece dentro do
bootstrap/IPC do WebProcess, antes de `WebKit view ready`.

O trace temporário posterior confirmou que o WebProcess já executa a sequência
real de `arch_prctl`, `set_tid_address`, `mmap`, `munmap`, futexes,
`mprotect`, abertura/leitura de arquivos e chamadas internas de inicializador
(`460`). Depois ele emite um novo `Linux PT_INTERP loader ready`, mas ainda
não chega ao frame HTML. O trace foi removido; não há syscall falsa adicionada.

Em 16/09/2026, a revisão do ABI do `clone` encontrou dois erros no contexto de
filhos: o argumento do callback era gravado no slot de `R12` em vez de `RDI`, e
o caminho `CLONE_VFORK` reusava a prioridade do pai. O kernel agora grava o
argumento em `frame[9]`, agenda o filho vfork imediatamente e usa `RSP + 8`,
como o `clone_start` de musl após o `pop %rdi`/`jmp`. O probe real de
`pthread_create`/TLS/join continua emitindo `CSOS WebKit prerequisite PASS:`
após a alteração. O smoke WPE ainda não alcançou `WebKit view ready`; a
execução seguinte permanece necessária para validar o callback e o handshake.

Uma execução instrumentada em 15/09/2026 foi correlacionada com o disassembly
upstream de `WebKit::ProcessLauncher::launchProcess()`: após a criação da
thread, o pai pode permanecer em um `lock cmpxchg` de `WordLock`, sem syscall,
enquanto o worker precisa executar para liberar o estado. O caso exigiu
preempção de userspace preservando frames, TLS, CR3 e ownership de workspace;
não é correto fabricar `WebKit view ready`.

### Preempção de userspace validada em QEMU (2026-09-16)

O vetor 32 agora distingue frames CPL3, preserva os quinze registradores,
reconhece o seletor de código de userspace e entrega o frame ao scheduler Zig.
O retorno reconhece o LAPIC antes de restaurar `RAX`; o probe pthread/TLS/DRM
continua passando. A política concede um quantum de graça ao criador pthread e
depois alterna threads runnable do mesmo workspace, sem antecipar processos
fork/vfork.

No smoke WPE, a mudança atravessou `WebKit view begin` e criou threads reais
adicionais do WebProcess. O gate ainda para antes de `WebKit view ready`; não há
evidência de handshake IPC completo, HTML carregado ou frame no compositor.
O próximo diagnóstico deve seguir a primeira thread WPE após essas trocas.

O estado usado por `iretq` passou a ser separado do frame `syscall/sysret`:
cada thread mantém RIP, RFLAGS, RSP e os quinze GPRs do timer, enquanto o
frame de syscall continua reservado para retornos Linux. O probe QEMU de
pthread/TLS/DRM permanece aprovado após essa correção; o handshake WPE ainda
é o gate aberto.

### Workers pthread do WebProcess (2026-09-16)

O scheduler não deixa mais a prioridade `active_user_thread` do criador
suprimir indefinidamente os workers adiados. Quando há workers runnable,
eles recebem o próximo turno antes da preferência do pai. Com as interrupções
de usuário desativadas apenas para isolar o teste, o probe real alcança
`CSOS WebKit threads PASS: mutex/condition/shared-memory/TLS/join
counter=300`. Com `RFLAGS.IF` habilitado, QEMU ainda rejeita o vetor de timer
32 com `#GP(0x102)` durante a entrada CPL3; portanto esta correção não marca
`WebKit view ready` e o próximo gate é corrigir a entrega segura do timer.

### Reserva de memória do IDT (2026-09-16)

O diagnóstico seguinte mostrou que a entrada do timer estava válida após a
paginação e antes do launcher, mas era sobrescrita quando o loader alocava o
ELF grande do WebKit. A tabela de páginas físicas tratava a região estática do
kernel como reutilizável. O allocator agora remove explicitamente as duas
páginas que contêm o IDT antes de criar tabelas ou carregar imagens. O teste
QEMU posterior confirmou que o launcher atravessa `WebKit view begin` e cria
workers adicionais sem o `#GP(0x102)` causado pela entrada zerada. O gate
`WebKit view ready` ainda não foi atingido; o bloqueio seguinte permanece no
handshake/loop do WebProcess.

### Intervalo do timer de preempção (2026-09-16)

O probe real de pthread/TLS/shared-memory/join continuava parado quando o
vetor de timer era recarregado com `100000` ciclos. A execução mantinha o
`RFLAGS.IF` habilitado, mas a frequência de interrupções consumia o tempo de
userspace no QEMU antes de o worker completar o bootstrap. Aumentar o reload
para `10000000` ciclos preserva a preempção e fez o probe produzir
`CSOS WebKit threads PASS: mutex/condition/shared-memory/TLS/join counter=300`.
O smoke WPE também avançou por `WebKit view begin` e criou workers adicionais,
mas ainda não produziu `WebKit view ready`; portanto este é um ajuste de
frequência/estabilidade do scheduler, não a conclusão do gate WebKit.

### Diagnóstico do caminho de spawn (2026-09-16)

Uma execução de 30 segundos com instrumentação temporária no syscall `execve`
não registrou nenhuma chamada com o caminho `WPEWebProcess`. O launcher ainda
chega a `WebKit view begin` e cria clones `CLONE_VM|CLONE_VFORK`, mas o callback
do filho não alcança o `execve` que substituiria a imagem. A instrumentação foi
removida após o teste; não há syscall falsa nem marcador de sucesso no kernel.
Isso estreita o bloqueio para o callback/file-actions do `posix_spawn` (antes da
troca de imagem), e não para o loader ELF do WebProcess.

Um probe musl adicional reproduziu as operações do GLib (`dup2`, `close`,
`POSIX_SPAWN_SETSIGDEF`) e usou `/bin/busybox` como imagem conhecida. O filho
alcançou `CSOS WPE WebProcess scheduled` e executou a imagem substituta, portanto
o callback e o `execve` funcionam nesse cenário. O processo pai, porém, não
retornou de `posix_spawn` dentro da janela do teste; o próximo ponto a
investigar é a publicação de EOF/reaperação do pipe de sincronização e o
desbloqueio do pai vfork após o `execve`, não a construção das file-actions.

Uma captura posterior do frame do clone WPE mostrou que o kernel grava o RIP
do callback, o argumento em RDI e o RSP alinhado (`RIP=0x6020088210`,
`RDI=0x900001cc20`, `RSP=0x900001e220`). Na mesma execução não apareceu
`CSOS WPE WebProcess scheduled`, indicando que o frame ainda não atravessa a
primeira execução efetiva do filho. A instrumentação foi removida; os valores
servem apenas para orientar a próxima comparação com o trampoline de clone do
musl.

## Referências upstream

- [Arquitetura WPE](https://wpewebkit.org/about/architecture.html): backend de
  apresentação desacoplado e encaminhamento de input.
- [Ports upstream](https://docs.webkit.org/Ports/Introduction.html): WPE e
  JSCOnly são ports diferentes; JSCOnly não oferece layout HTML/CSS.
- [Roteiro histórico de portabilidade](https://trac.webkit.org/wiki/SuccessfulPortHowTo):
  JavaScriptCore antes de WebCore. Usar apenas como orientação, não como lista
  atual e completa de dependências.
