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

## Reprodução mais recente (2026-09-21)

### Relink do loader WPE e submissão HTML (2026-09-23)

O smoke de 180 s revelou que o `libWPEWebKit-2.0.stripped.so` copiado para o
disco ainda era anterior ao relink: o WebKit principal alcançava
`WebKit view ready`, mas o segundo processo abortava porque o
`_wpe_loader_interface` zerado do `wpe-loader-link-stub.o` ocultava o
`load_object` real do backend FDO. O relink remove esse stub e declara
`libWPEBackend-fdo-1.0.so.1` como dependência dinâmica; o script agora também
regenera automaticamente a cópia stripped consumida pelo runner.

Após recriar `nvme.img` com esse runtime, o QEMU confirmou a sequência real
`WebKit view ready` → `WebKit HTML submitted` → `WebKit GLib loop complete`.
O callback de exportação ainda não ocorreu: o processo termina em um RIP
inválido dentro da desmontagem/execução posterior, portanto
`WebKit first frame` permanece aberto. O QEMU foi encerrado pelo runner.

### Correção de `CLONE_PARENT_SETTID` em vfork (2026-09-23)

O watchpoint de hardware no QEMU identificou a origem do valor inválido que
aparecia no allocator do WebProcess. O kernel escrevia o TID no argumento
`parent_tid` sempre que ele era não nulo, mesmo quando o clone `0x4111`
(`CLONE_VM|CLONE_VFORK|SIGCHLD`) não continha `CLONE_PARENT_SETTID`. Esse
argumento é usado como scratch pelo caller; a escrita de `6` sobre o endereço
`0xa00e21ee00` produzia `0xa000000006` e corrompia a lista liberada depois.

`cloneThread` agora publica `parent_tid` somente quando o flag
`CLONE_PARENT_SETTID` está presente. A suíte `zig build test` e o build
`ReleaseSmall` passam. Um smoke WPE de 50 s alcançou
`CSOS WPE WebProcess scheduled`; outro de 90 s alcançou `WebKit view ready`
sem o valor inválido. O gate de HTML/frame ainda precisa de validação; nenhum
marcador sintético foi adicionado e o QEMU foi encerrado ao final dos testes.

Com um cache de build limpo e o launcher/processos WPE reais, o smoke em QEMU
atingiu de forma reproduzível `FAT WebKit entry ready`, carregou os
inicializadores ELF, iniciou o WebProcess e emitiu `WebKit view ready`. O teste
de 100 s terminou depois desse marcador sem observar `WebKit HTML submitted`;
portanto o gate de primeiro HTML/frame continua aberto. O QEMU foi encerrado
automaticamente após o timeout. A suíte nativa permaneceu verde: 54 steps e
257 testes aprovados.

Durante essa reprodução também foi corrigida a montagem dos argumentos do
runner: quando RADV e WPE eram solicitados juntos, `run.ps1` recebia
parâmetros escalares duplicados (`Zlib`, `Libc` e `Libdrm`), fazendo o smoke
falhar antes do boot. O build agora emite esses caminhos uma única vez.

Em 2026-09-22, dois smokes delimitados adicionais (100 s e 180 s) mantiveram
`WebKit view ready` reproduzível. A instrumentação temporária dos caminhos de
retomada de syscall, timer e `resume_user_frame` não registrou RIP baixo nem
frame inválido. A falha tardia observada em uma das execuções ocorreu depois
de três threads pthread do WebProcess, com page fault de instrução em
`RIP=0x1072b4de8` (`code=0x14`); outra execução repetiu o fault legado em
`RIP=0x10`. Isso separa o bloqueio atual do spawn/seleção inicial: o próximo
diagnóstico deve seguir o estado/ABI do WebProcess/JSC e o mapeamento do alvo
executável, sem transformar esses faults em sucesso. Toda a instrumentação foi
removida após a captura.

A correção também tornou o registro `rseq` específico por thread. O estado
global anterior fazia workers WPE/GLib posteriores receberem `EBUSY` ao
registrar sua área, contrariando o contrato Linux. Cada thread agora registra
e remove sua própria área, e um novo exec começa sem o registro da imagem
anterior. O smoke ainda precisa validar o fault tardio independentemente
dessa correção.

Uma captura adicional do ABI de `pthread_create` confirmou que, para cada
`clone(0x7d0f00)`, o stack callback contém uma estrutura válida e o primeiro
campo aponta para `musl start` no momento em que o kernel cria a thread. O
`RIP=0x10` só aparece posteriormente, já no bootstrap do processo auxiliar;
portanto o próximo diagnóstico deve observar a corrupção dessa estrutura
entre a criação e a execução do callback, sem alterar artificialmente o
retorno do clone.

O diagnóstico seguinte isolou o próximo bloqueio: imediatamente depois de
`WebKit view ready`, o launcher solicita `clone(0x4111)` para o processo
auxiliar, mas o marcador de `execve` desse filho não aparece e
`webkit_web_view_load_html()` não retorna. A continuação musl observada no
clone tem RIP de retorno, R9 callback e stack válidos; trocar para uma entrada
direta no callback não resolveu. Rearmar o APIC timer especificamente nessa
fase também não é uma correção: a preempção antecipada provoca faults durante
o bootstrap do WebKit. Essas tentativas foram removidas e nenhum marcador
sintético foi adicionado.

Uma correção de scheduler deu prioridade à criança `CLONE_VFORK` recém-criada
antes de pthreads com `pending_wait_status`. O smoke de 180 s confirmou o
avanço adicional: o filho agora chega a `exec request .../WPENetworkProcess`,
o loader termina e o processo WebKit é agendado. O teste ainda termina em um
`#GP` dentro do bootstrap/JIT do processo auxiliar, antes de
`WebKit HTML submitted`; esse é o novo gate a investigar.

## Reprodução mais recente (2026-09-16)

`zig build test` terminou com sucesso. O smoke real em QEMU (`SmokeTestSeconds
30`) inicializou o kernel, armazenamento FAT16 e iniciou a preparação do
launcher WPE (`FAT WebKit entry ready`), mas expirou sem `WebKit view ready`.
O log e o stderr foram preservados em `zig-out/smoke-3a768b3ec26d495dbf7ec871ba0e8304.serial.log`
e `zig-out/smoke-3a768b3ec26d495dbf7ec871ba0e8304.stderr.log`. Nenhum sucesso
sintético foi adicionado; o gate de WebKit continua aberto.

O handler de timer para interrupções vindas do ring 3 foi corrigido para
reservar a shadow space e o alinhamento exigidos pelo ABI Microsoft x64 antes
de chamar o dispatcher Zig, restaurando depois o ponteiro original. No smoke
de 60 s seguinte, o WebProcess real avançou até `CSOS WPE WebProcess scheduled`
sem reset/triple fault. `WebKit view ready` ainda não foi observado; o próximo
bloqueio está no bootstrap/IPC posterior do WebProcess.

O smoke de 120 s de 2026-09-16 confirmou o avanço até
`CSOS WPE WebProcess scheduled` após tratar faults de execução em páginas
presentes e NX dentro da arena `MAP_NORESERVE` do JavaScriptCore. O handler
promove a página para executável via `mprotect`/page-table update e invalida o
TLB. A execução ainda é intermitente: outro boot terminou em `#GP(0x102)` ao
entregar o timer após o primeiro fault do WebProcess. Não há marcador
`WebKit view ready`; o gate permanece aberto e o próximo diagnóstico é tornar
estável a entrega de interrupções durante o bootstrap/IPC do WebProcess.

Uma instrumentação temporária no último timer válido confirmou que a entrada
IDT32 continua com attr=0x8e, seletor 0x08 e IST=1; o descritor de código GDT
(0x00af9a000000ffff) e o TSS (0x39008b600b20006f) também permanecem
inalterados. O #GP(0x102) não é causado por uma escrita direta
nesses descritores; a investigação segue no estado de entrega/retorno da
interrupção.

Com a IDT recarregada, o WebProcess chega ao bootstrap de JavaScriptCore e
emite "Invalid value for lock: 0", seguido de um page fault de leitura em
CR2=0x1 dentro de jsc_weak_value_get_value. A trilha temporária dos
syscalls confirma que o fault ocorre depois de futexes, mmap e inicializadores;
o próximo gate é corrigir a sincronização/estado inicial desses locks, não
fabricar o marcador de view.

Uma reprodução completa adicional em 2026-09-16 (`SmokeTestSeconds 120`) chegou
novamente a `CSOS WPE WebProcess scheduled` e terminou em
`cpu 0 page fault at 1 rip 412417723183 code 5`. O QEMU foi encerrado após a
captura. Isso confirma que o bloqueio permanece determinístico no bootstrap do
WebProcess, antes do primeiro frame, e que nenhum push de código deve declarar
o gate concluído sem observar `WebKit view ready`.

O dump de exceções desse boot mostra a sequência `CR2=0xe000000010` (fault de
commit da arena anônima, código 6), seguido de `CR2=0x1` (leitura, código 5,
`RAX=1`) em `0x6006030b2f`. A página da arena é criada pelo handler de demanda;
o segundo fault demonstra que o bootstrap forneceu um ponteiro inválido ao
JSC, não que o endereço da instrução esteja sem mapeamento.

O trace temporário de sincronização confirmou que o WebProcess usa
`FUTEX_WAIT_PRIVATE`/`FUTEX_WAKE_PRIVATE` (operações 128/129), ambas cobertas
pela implementação atual; os waits com palavra divergente seguem o retorno
Linux `EAGAIN`. O trace foi removido após a reprodução e não altera o runtime.

Também foi testada, sem commit, a remoção do varrimento genérico de futexes em
`releaseOwnedFutexesOnExit`, preservando somente a robust list Linux. O smoke
completo manteve o mesmo `CSOS WPE WebProcess scheduled` seguido de
`CR2=0x1`; a hipótese de um lock zerado durante a saída de uma thread foi
descartada para este fault.

O probe de pré-requisitos agora cobre também `pthread_key_create`,
`pthread_setspecific` e `pthread_getspecific`; no QEMU o marcador
`CSOS WebKit threads PASS` foi observado com valores distintos por thread.
Assim, o TLS de chaves POSIX não é o bloqueio reproduzido no WebProcess.

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

Um trace controlado após `activateExecThread` mostrou que o novo image de fato
entra no dispatcher e executa `close` seguido de várias chamadas
`rt_sigaction`. Portanto, o bootstrap não está parado no `iretq`; o próximo
gargalo está no progresso da inicialização de sinais/estado libc do WebProcess
e sua transição subsequente para o loop IPC.

Em 16/09/2026, o launcher passou a receber um ambiente mínimo real
(`HOME`, `USER`, `LOGNAME`, `PATH` e `XDG_RUNTIME_DIR`) antes de iniciar o
WPE. Isso removeu os avisos de identidade/diretório HOME do GLib e confirmou
que o WebProcess ainda alcança `CSOS WPE WebProcess scheduled`; porém o smoke
de 90 s continua sem `WebKit view ready`. O ajuste foi validado com
`zig build test` e não fabrica nenhum marcador de sucesso.

Uma captura instrumentada em QEMU (`zig-out/smoke-ac8f745d60b24d8f922a6ad82818c70a.serial.log`)
mostrou a seleção efetiva do filho `CLONE_VFORK`: após `close`, múltiplos
`rt_sigaction`, `dup2`, `fcntl`, `rt_sigprocmask` e `execve`, um segundo filho
é selecionado e o loader emite `CSOS WPE WebProcess scheduled`. Isso elimina a
hipótese de starvation do scheduler como causa única; o bloqueio permanece no
bootstrap do image replacement seguinte, antes de qualquer novo frame WebKit.

Um marcador temporário no primeiro instruction de `ld-csos` produziu `S` para
o launcher normal, mas nenhum `S` depois de `CSOS WPE WebProcess scheduled`.
Na execução correspondente (`zig-out/smoke-12c121e59a824857a1e618903da51a98.serial.log`),
isso restringe o próximo diagnóstico à entrada do segundo image (iret/CR3,
RIP e RSP efetivos), antes do `_start` e de qualquer syscall libc.

O trace de exceções do QEMU (`-d int,cpu_reset`) confirmou que o reset após
`CSOS WPE WebProcess scheduled` era um `#GP(0x102)` ao entregar o vetor de
timer `0x20`, seguido de `#DF`/triple fault. A IDT estava reservada, mas as
áreas estáticas de GDT/TSS e das pilhas RSP0/IST não estavam protegidas do
alocador físico. Elas agora são reservadas explicitamente; o smoke precisa ser
repetido para verificar a entrega do timer sem reset.

A auditoria dos ELF confirmou que `libWPEWebKit` e `libWPEBackend-fdo` importam
`sendmsg` e `recvmsg` (além de `socketpair`). O dispatcher CSOS ainda não expõe
esses syscalls; um protótipo somente para iovecs foi testado e removido porque
não trata `SCM_RIGHTS`/ancillary FDs e não avançou o smoke. O próximo trabalho
de IPC deve implementar o layout Linux de `msghdr` com transferência de FDs
real, ou provar que o caminho de inicialização não o utiliza.

Uma captura subsequente registrou a tentativa de entrada com `RIP=0x70000012ac`
e `RSP=0x900001f550`, ambos dentro das regiões ELF/stack esperadas. O próximo
passo é validar o estado efetivo do CR3 e a entrega do `iretq` nesse contexto;
não há ainda evidência suficiente para marcar `WebKit view ready`.

Essa validação foi executada diretamente após o clone do workspace: o `CR3`
filho preserva o mapeamento da IDT (`child IDT map=1`). Portanto, o
`#GP(0x102)` não é causado por uma tabela de páginas filha sem a IDT; a próxima
comparação deve focar o estado dos descritores GDT/TSS e da entrega do gate no
CPU que executa o WebProcess.

Uma verificação equivalente das quatro regiões reservadas de GDT/TSS/RSP0/IST1
no mesmo `CR3` também retornou `map=1` para todas. Os dados estáticos de
segmentação e as pilhas de exceção estão presentes no espaço filho; resta
comparar o GDTR/TR efetivos no instante da entrega do timer.

O snapshot capturado imediatamente após a ativação do workspace filho também
mostrou `GDTR.limit=0x37` e `TR=0x28`, iguais aos valores instalados no BSP e
observados no trace do QEMU. A troca de `CR3` não altera esses registradores;
o ponto restante é a validação do gate no instante em que o LAPIC entrega o
vetor `0x20`.

O trace de `dup2` em `zig-out/smoke-6a28284e86794e0b849dc459dc72bc60.serial.log`
confirmou `dup enter`/`dup exit` para os dois remapeamentos do filho. Assim,
`dup2` retorna normalmente; o próximo diagnóstico deve seguir o syscall
subsequente e a troca de contexto, sem alterar a contabilidade de descritores
com base apenas no timeout.

Também foi corrigido o índice do RBP no frame SysV usado pelo callback de
`CLONE_VFORK`: a captura coloca RBP no slot 11 (não no slot 5, que é R12).
`zig build test` permanece verde; o smoke WPE segue necessário para provar que
essa correção elimina a intermitência de entrada.

Em 16/09/2026, uma instrumentação temporária do caminho `CLONE_VFORK` confirmou
que o contexto do filho é montado e selecionado (`CSOS vfork child switch`). Em
uma repetição o novo processo chegou ao primeiro `close(3)`; em outras, parou
antes do primeiro syscall, sempre sem `WebKit view ready`. Os marcadores foram
removidos após o diagnóstico e `zig build test` passou. O gate continua aberto:
o próximo passo é comparar a entrega efetiva do `sysretq`/frame de entrada nas
duas execuções, sem adicionar sucesso sintético.

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
counter=2000` (8 workers × 250 iterações, com `sched_yield()` enquanto o
mutex está retido). Com `RFLAGS.IF` habilitado, QEMU ainda rejeita o vetor de timer
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
`CSOS WebKit threads PASS: mutex/condition/shared-memory/TLS/join counter=2000`.
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

### Syscalls de mensagem antes do view-ready (2026-09-16)

O dispatcher agora implementa os números Linux 46 (`sendmsg`) e 47
(`recvmsg`) com o layout real de `msghdr`/`iovec`, validação de slices e
retornos parciais/EAGAIN. O smoke ainda atinge `WebKit view begin` sem registrar
essas syscalls antes de parar; portanto, elas não explicam o bloqueio dentro de
`webkit_web_view_new()` nesse estágio. A passagem de descritores por
`SCM_RIGHTS` continua pendente para o IPC completo; a próxima investigação deve
focar o loop de criação do view/worker anterior ao primeiro uso de mensagens.

### ABI do callback vfork (2026-09-16)

O frame de entrada direta do callback `CLONE_VFORK` agora zera `RBP`, como faz
o trampoline `__clone` do musl antes do `CALL` (`xor %ebp,%ebp`). O smoke
QEMU confirmou a progressão de `CSOS vfork child selected` até a entrada real
em `execve`; antes desse ajuste o callback não produzia nenhuma syscall. O
ELF `WPEWebProcess` ainda não chega a `CSOS WPE WebProcess scheduled`, então o
gate permanece aberto e a próxima investigação é o processamento do
`ExecRequest` após essa entrada.

### Primeiro agendamento do WebProcess (2026-09-16)

Um smoke com o ajuste de ABI alcançou novamente `CSOS WPE WebProcess
scheduled`, confirmando que o `ExecRequest` foi consumido, o ELF do
WebProcess foi carregado e o workspace filho foi ativado. Nessa execução não
houve nenhuma marca de syscall posterior antes do encerramento do QEMU; o
próximo diagnóstico deve verificar a primeira entrada em userspace/CR3 do
WebProcess, antes de voltar ao caminho de futex ou IPC.

### Entrada do workspace WebProcess (2026-09-16)

Foi usado um marcador temporário no primeiro syscall do interpretador ELF. Em
execuções que chegaram a `CSOS WPE WebProcess scheduled`, o marcador apareceu
somente no launcher (`Linux PT_INTERP loader ready`), nunca no processo filho.
Isso confirma que o ELF foi carregado, mas a primeira entrada ring-3 do novo
workspace não alcança sequer `_start`; o próximo diagnóstico deve capturar a
entrega do `iretq`/CR3 e possíveis exceções antes do primeiro syscall. O
marcador foi removido após o teste.

### Watchpoint de descritores (2026-09-16)

Um smoke com gdbstub observou simultaneamente o byte de atributos do gate do
IDT e o descritor de código `GDT[1]` (`CS=0x08`). Ambos receberam somente a
escrita esperada durante `idt.install`/`gdt.install`; nenhuma escrita posterior
foi capturada antes do `#GP(0x102)`. A hipótese de corrupção direta dos
descritores foi descartada. O diagnóstico deve agora comparar a tradução do
endereço do IDT e a validação do gate após a troca para o CR3 do WebProcess.

A comparação correta das PDEs confirmou que o endereço virtual do IDT resolve
para a mesma página física no pai e no clone (`1000968192` em ambos), inclusive
quando a entrada é uma PDE de 2 MiB. Inicializar previamente os bits accessed
dos descritores de código também não alterou o resultado. A próxima captura
deve examinar o estado completo do gate/TSS no instante da entrega, não a
alocação ou o conteúdo da página.

### Exceção do timer em ring-3 (2026-09-16)

O runner agora aceita `-CaptureExceptions`, preservando o log de exceções do
QEMU em `zig-out/qemu-exceptions.log`. A captura reproduzível mostra vários
`Servicing hardware INT=0x20` no launcher/WebProcess e, em seguida,
`#GP vector 13 error=0x102` durante a entrega do timer, seguido de triple
fault. Desativar o timer apenas interrompe o progresso do launcher e não é
uma solução; o gate exige corrigir a entrada do vetor 0x20 mantendo a
preempção ativa.

### Callback do timer isolado (2026-09-16)

Uma execução adicional registrou o mesmo `#GP(0x102)` mesmo com o hook
`userTimerSwitch` temporariamente removido. Portanto a falha ocorre antes da
execução do callback, na validação/entrega da entrada de hardware pelo CPU;
restaurar o hook não altera o diagnóstico. O próximo passo é validar o estado
completo de TSS/IST e os seletores no instante da troca para o CR3 do
WebProcess.

### Separação entre timer comum e CR3 do WebProcess (2026-09-16)

Um smoke sem WebKit manteve dezenas de interrupções reais do LAPIC em ring-3
sem exceção. Repetindo o mesmo caminho com o launcher WPE, o primeiro
`#GP(0x102)` aparece somente depois da ativação do CR3 filho. Isso elimina o
callback e a configuração global do timer como causa suficiente; a próxima
captura deve comparar o mapeamento efetivo do código do handler e das páginas
de tabelas no CR3 filho, no instante anterior à entrega.

Uma verificação instrumentada posterior confirmou `WPE timer page map=1`
imediatamente antes de `CSOS WPE WebProcess scheduled`; portanto a página do
handler está presente no CR3 filho. O `#GP(0x102)` ocorre ainda na validação
do gate/segmentação, antes da primeira instrução do WebProcess.

Uma captura do clone confirmou que IDT, GDT e o handler do timer resolvem para
os mesmos endereços físicos do kernel (`WPE phys idt=1000968192`, com GDT e
handler também em mapeamentos identity). Assim, a tradução dessas páginas não
explica o `#GP(0x102)`; resta validar o descritor efetivo e a segmentação no
instante da entrega pelo CPU.

### ABI do page fault corrigida (2026-09-16)

Durante a captura do WebProcess surgiu um segundo defeito independente: o
stub de page fault chamava `page_fault_dispatch` com registradores SysV,
enquanto o kernel usa Microsoft x64. A correção agora passa endereço, RIP e
erro em `RCX/RDX/R8`; o log deixa de reportar valores falsos como `rip 6`.
O `#GP(0x102)` do timer ainda ocorre depois de vários ticks, portanto esse
ajuste corrige o diagnóstico/reclaim de páginas mas não fecha o gate do WPE.

### Validação do descritor ao vivo (2026-09-16)

Foi adicionada uma guarda temporária no início do handler do timer para conferir
`selector=0x08`, `IST=1` e `attributes=0x8e` no `IDT[32]` antes de preservar os
registradores. A guarda nunca disparou durante o smoke: o descritor permanece
válido até o instante em que o CPU rejeita a entrega com `#GP(0x102)`. O teste
foi removido após a captura; o próximo diagnóstico deve observar o descritor de
código `GDT[1]`, o TSS efetivo e o endereço-alvo da gate no CR3 do WebProcess.

Uma guarda adicional leu os offsets corretos de `GDT[1]` e do descritor TSS no
mesmo instante. Nenhuma das duas verificações disparou; o marcador `C` obtido
numa tentativa anterior era um falso positivo causado por ler o descritor nulo
(`GDT[0]`).

Também foi reconstruído o offset completo (`low/middle/high`) do `IDT[32]` e
comparado ao endereço de `timer()`. O alvo coincide no CR3 filho; portanto o
`#GP(0x102)` não vem de truncamento do offset da gate. A instrumentação foi
removida após o smoke.

Uma checagem do ponteiro `TSS.IST1` usando o layout packed correto (offset 36)
também permaneceu válida durante todo o smoke. O valor da pilha de interrupção
não é a origem do `#GP`; a instrumentação foi removida.

### Isolamento do callback de preempção (2026-09-16)

O callback `userTimerSwitch` foi desabilitado apenas para diagnóstico, mantendo
o mesmo frame de interrupção e o retorno normal do handler. O smoke reproduziu
o `#GP(0x102)` sem executar o callback; a falha não está na seleção de thread,
`fxsave/fxrstor` ou troca de workspace. A alteração foi revertida após o teste.

Um marcador protegido colocado após todos os `popq` do handler também foi
observado repetidamente antes do `iretq`. Isso confirma que a restauração dos
registradores e a saída da interrupção completam; o `#GP(0x102)` só aparece na
entrega de um tick posterior, já de volta ao contexto ring-3.

### Fault tardio no WebProcess (2026-09-16)

Uma reprodução de 125 segundos com `-CaptureExceptions` confirmou que o
problema já não é o spawn: o processo chega a `CSOS WPE WebProcess scheduled`
e ao segundo `Linux PT_INTERP loader ready`. O primeiro `#PF` ocorre em
`RIP=0x600602dab7`, `CR2=0xe000000010`, código `0x6`, durante o primeiro
toque de escrita da arena anônima `MAP_NORESERVE`; o pager resolve essa falta.
Logo depois, o WebProcess sofre `#PF` de leitura em `RIP=0x6006030b2f`,
`CR2=0x1`, código `0x5`, com `RAX=1` e `R8=0xe000000000`, e fica parado antes
de `WebKit view ready`. O segundo acesso é um ponteiro efetivamente inválido
no código JSC (não uma falta que o pager deva aceitar), então o próximo passo
é rastrear a inicialização do objeto/tabela que usa a arena, incluindo o
conteúdo escrito entre os dois faults; não será adicionado retorno de sucesso
falso para esconder essa exceção.

### Auditoria do RIP contra o ELF (2026-09-17)

Uma captura temporária dos bytes da página executada confirmou que o WebProcess
executa exatamente o artefato usado pelo runner,
`libWPEWebKit-2.0.stripped.so`. O offset `0x6030b2f` contém
`mov (%rax),%rdx` em uma rotina interna do allocator (o símbolo exportado
mais próximo é apenas um rótulo de disassembly), coerente com `CR2=0x1` e
`RAX=1`. A comparação anterior com o ELF não-estripado foi inválida porque os
dois arquivos têm layout de código diferente. O page-table e o pager não estão
fornecendo bytes incorretos; o próximo diagnóstico deve seguir a inicialização
do estado do allocator/JSC que chega com esse ponteiro, sem ignorar a exceção.

### Semântica MAP_FIXED zero-fill (2026-09-17)

O caminho `MAP_FIXED|MAP_NORESERVE` passou a desmapear e liberar páginas lazy
já tocadas antes de devolver o mesmo endereço, reproduzindo o zero-fill de
`mmap(MAP_ANON|MAP_FIXED)` usado por `vmZeroAndPurge`. `zig build test` passou,
mas o smoke WPE de 130 segundos manteve o mesmo `CR2=0x1` antes de
`WebKit view ready`; portanto essa correção de semântica é necessária, mas não
é ainda a causa imediata do fault inicial.

### Sequência de reservas `MAP_NORESERVE` (2026-09-16)

Instrumentação temporária do syscall `mmap` mostrou os endereços efetivamente
retornados pelo launcher: `0xa000031000` (128 MiB), depois pequenos blocos no
intervalo `0xa008...`. Ao criar o view, a arena de 128 GiB foi reservada em
`0xc000000000`; o WebProcess recebeu a arena seguinte em `0xe000000000`.
Todas as chamadas usaram `requested=0` e flags `0x4022`, portanto o kernel não
está aceitando um endereço fixo solicitado pelo WebKit nesse caminho. Uma
reserva intermediária de aproximadamente 1 GiB não produziu endereço de
retorno antes da chamada seguinte de 8 GiB; isso deve ser investigado como
erro de alocação/limite, não tratado como sucesso implícito. A instrumentação
foi removida depois da captura.

### Isolamento de hipóteses de TLS e mmap (2026-09-17)

Uma instrumentação no `clone` confirmou que as threads pthread recebem um
`tls` com `self->tsd` válido. O fault observado em `pthread_getspecific` só
apareceu quando se tentou restaurar cursores de mmap por workspace sem também
alterar todos os caminhos de ativação de CR3; esse experimento foi revertido
por introduzir um fault prematuro no arena eager. A tentativa de preencher
`self->tsd` dentro de `ARCH_SET_FS` também não alterou o fault WPE reproduzível.
O baseline permanece, portanto, no acesso JSC inválido `CR2=0x1`; não há
mudança de kernel não validada mantida para mascará-lo.

### Exclusão de remapeamento da arena (2026-09-17)

Uma execução de 125 segundos registrou o primeiro toque da arena em
`0xe000000000` exatamente uma vez (`existing=0`), seguido do mesmo fault JSC
em `CR2=0x1`. Não houve segundo page fault nem remapeamento dessa página antes
do acesso inválido. A hipótese de que o pager estaria substituindo a página e
apagando o objeto foi descartada; a investigação deve continuar na
inicialização/ABI do objeto JSC e nas operações de commit/proteção posteriores.

Um smoke adicional com `JSC_useJIT=0` produziu o mesmo `RIP=0x6006030b2f`,
`RAX=1` e `CR2=0x1`. O bloqueio não depende do backend JIT; a variável de
diagnóstico foi removida após o teste.

No segundo fault, uma leitura temporária da página já tocada mostrou os dois
primeiros words como `1` e `0xe000000000` (o endereço da própria arena). A
página não estava zerada nem perdida; o valor inválido já havia sido escrito
pelo código userspace antes da leitura em `CR2=0x1`. A instrumentação foi
removida após a captura.

O smoke também foi repetido com QEMU limitado a um único vCPU (`-smp 1`).
O WebProcess reproduziu o mesmo `RIP=0x6006030b2f`/`CR2=0x1`; o runner foi
restaurado para quatro vCPUs. Isso exclui uma corrida que dependa de execução
SMP como causa imediata do fault.

### Cursor após caudas MAP_FIXED (2026-09-17)

O caminho `MAP_FIXED|MAP_NORESERVE` agora também avança `noreserve_next` até
o fim do intervalo fixado. Isso evita que uma reserva não-fixa reutilize a
cauda alinhada de uma arena já entregue ao bmalloc e sobrescreva metadados do
allocator. O teste de 130 segundos deixou de reproduzir o `#PF` em
`CR2=0x1`/`RAX=1` e avançou até a validação de lock do runtime (`Invalid value
for lock: 0`), seguida por `#GP(0)` em ring 3; `WebKit view ready` ainda não
foi observado. O próximo diagnóstico é localizar a inicialização desse lock,
sem fabricar sucesso para o gate.

### Smoke real com os dois subprocessos WPE (2026-09-17)

Após remover os diagnósticos temporários, `zig build test` passou novamente.
Um smoke QEMU de 30 segundos com os ELFs reais de `WPEWebProcess` e
`WPENetworkProcess` reproduziu o limite atual: `WebKit view begin`, seguido de
`Linux PT_INTERP loader ready`, mas sem `WebKit view ready`. As reservas
observadas foram `128 GiB @ 0xc000000000` e depois `128 MiB @ 0xe000000000`,
sem sobreposição. O fault posterior ocorre em `0x6006030b2f`, numa leitura de
tabela interna do JSC (`mov (%rax), %rdx`) com `CR2=0x1` e `RAX=1`, depois do
primeiro commit lazy em `0xe000000000`. Portanto o próximo diagnóstico deve
concentrar-se na inicialização/ABI do allocator JSC; o gate WebKit e o primeiro
frame continuam abertos.

A captura dos registradores no segundo fault confirmou a operação: `R8` aponta
para `0xe000000000`, `R15=0`, e a instrução calcula `RAX = R15 * 24 +
*(u64*)R8`; o primeiro word da arena vale `1`, produzindo `CR2=0x1`. A página
foi criada por demanda e não foi remapeada antes da leitura. O próximo passo é
comparar esse layout com o contrato de `pas_simple_large_free_heap` e com a
sequência de `mmap`/commit esperada pelo libpas, em vez de alterar o pager sem
uma divergência demonstrada.

### Proteção contra remapeamento de página presente (2026-09-17)

O pager tinha um caminho que tratava qualquer fault dentro da janela
`MAP_NORESERVE` como página ausente. Em um fault de proteção sobre uma página já
presente isso podia alocar outra página e substituir silenciosamente os bytes do
allocator. O caminho agora rejeita esse caso; somente páginas realmente
ausentes são comprometidas, enquanto a promoção NX→executável continua no
caminho explícito de `mprotect`. `zig build test` passa. O smoke WPE ainda
reproduz o fault JSC posterior, portanto esta correção elimina uma classe de
aliasing mas não fecha o gate `WebKit view ready`.

### Primeiro writer do allocator JSC (2026-09-17)

Uma proteção temporária de somente-leitura na primeira página comprometida de
`0xe000000000` capturou o primeiro write posterior como `RIP=0x600602e3b7`,
que corresponde a `pas_simple_large_free_heap_construct` e aos dois `movups`
que zeram o objeto. A página recebeu uma página física nova, sem sobreposição
com as ranges já pertencentes ao workspace (`owned-alias=0`). Assim, o objeto
começa íntegro; a transformação posterior em `[1, 0xe000000000, 1,
0xe000000000]` ocorre depois do construtor, na sequência de alocação/threads do
WebProcess. A instrumentação foi removida após a captura.

### Preservação SIMD em page faults (2026-09-17)

O primeiro writer identificado no allocator era `pas_simple_large_free_heap_construct`,
que usa `xorps` seguido de dois `movups` para zerar o objeto. O handler de page
fault executava código Zig entre a falta e a repetição da instrução sem salvar
os registradores XMM. O primeiro `movups` podia, portanto, ser seguido por um
segundo `movups` com `XMM0` alterado pelo kernel, gravando
`[1, 0xe000000000, 1, 0xe000000000]` no objeto.

O handler agora reserva uma área alinhada e executa `fxsave64` antes de chamar
`page_fault_dispatch`, restaurando com `fxrstor64` antes do `iretq`. Uma captura
temporária confirmou que os quatro words permanecem zerados após os dois
stores; o fault `CR2=1` deixou de ocorrer. O smoke avançou até o primeiro
syscall ainda não implementado (`434`, `pidfd_open`), sem `WebKit view ready`.

### pidfd_open e readiness em poll/epoll (2026-09-17)

O syscall `pidfd_open` (434) agora cria um descritor VFS próprio, validando o
PID e flags conforme Linux. O descritor é reconhecido por `poll` e `epoll`; ao
encerrar o processo monitorado, o kernel sinaliza sua readiness para que os
workers WPE possam sair de esperas sem depender de um `eventfd` disfarçado.
`zig build test` passa. O smoke seguinte deixou de registrar `unsupported
syscall 434`, mas ainda termina antes de `WebKit view ready`; o próximo
bloqueio precisa ser identificado no trap/ABI posterior do WebProcess.

### Preservação SIMD no timer preemptivo (2026-09-17)

Além do page fault, o timer APIC também chama código Zig durante a execução de
threads ring-3. O handler agora salva e restaura a área FPU/SSE com
`fxsave64`/`fxrstor64` ao redor desse callback. Isso fecha a segunda fronteira
que podia alterar registradores XMM enquanto uma instrução WebKit era
preemptada. `zig build test` passa; o smoke ainda reproduz um `ud2` interno do
WebProcess depois da criação de threads, portanto `WebKit view ready` continua
pendente e não foi mascarado.

### Cursores mmap por workspace (2026-09-17)

O launcher, o WebProcess e o NetworkProcess são address spaces distintos, mas
`mmap_next` e `noreserve_next` eram mantidos como variáveis globais do módulo de
syscalls. Ao alternar o workspace do scheduler, o processo seguinte podia
continuar alocando a partir da arena virtual do processo anterior. A captura
mostrou reservas consecutivas em `0xa008...` e o `PAS_ASSERT(min_node)` do
libpas nessa mesma região. Os cursores e os limites agora são salvos no
`LoaderWorkspace` e restaurados somente ao trocar de address space; uma troca
de thread dentro do mesmo workspace preserva o cursor corrente. O cursor
inicial também é herdado no clone. O smoke QEMU com os ELFs reais do
WebProcess/NetworkProcess agora produz `WebKit view ready` em 90 segundos.

### Submissão do primeiro HTML real (2026-09-17)

Um smoke delimitado de 300 segundos com os ELFs reais confirmou a sequência
`WebKit view ready` → `WebKit HTML submitted` → `WebKit GLib loop complete`.
Isso prova a submissão do documento pelo WebKit real, sem marcador sintético.
O launcher agora implementa o ciclo de vida do backend SHM: quando o WPE
exporta um `wpe_fdo_shm_exported_buffer`, ele consulta os metadados, libera o
buffer e despacha `frame_complete`. O callback ainda precisa ser observado
em um smoke estável para fechar o gate do primeiro frame e copiar os pixels ao
framebuffer; portanto o gate permanece aberto.

### Duplicação correta de descritores e teardown do backend (2026-09-17)

O caminho real do WPE/GLib usa `dup(2)`; o syscall Linux 32 foi ligado à
mesma implementação de `F_DUPFD`, preservando a escolha do menor descritor
livre. Durante o smoke, o page fault restante foi rastreado até
`wpe_view_backend_destroy`: o launcher destruía o backend explicitamente e
depois destruía o exportable FDO, que já é seu proprietário. O teardown foi
corrigido para ocorrer uma única vez. O smoke seguinte passou por
`WebKit GLib loop complete` sem page fault; o primeiro callback SHM ainda não
foi observado.

### Cadência FDO e estado inicial da view (2026-09-17)

O launcher passou a aplicar `visible | focused | in_window` antes de criar a
`WebKitWebView`, como no backend headless FDO de referência. O dispatcher de
`frame_complete` também é reexecutado após cada turno do contexto GLib, pois a
primeira chamada pode ocorrer antes do registro da superfície IPC. A libwpe/FDO
é responsável por chamar `frame_displayed` quando entrega callbacks; o cliente
não o chama manualmente. Esses ajustes alinham o contrato de cadência e
ownership, mas não fecham o gate: os smokes ainda não observaram o callback
SHM nem uma cópia para o framebuffer.

### Ponte SHM para o framebuffer (2026-09-22)

O launcher agora abre `/dev/fb0`, consulta `FBIOGET_VSCREENINFO` e
`FBIOGET_FSCREENINFO`, mapeia o scanout compartilhado e copia cada buffer SHM
exportado pelo WPE para o stride do framebuffer. O marcador
`CSOS framebuffer mapped` foi observado em QEMU; `WebKit first frame` só é
emitido dentro do callback de exportação, portanto não é um sucesso sintético.
Nos smokes de 60 s e 180 s o WebProcess ainda caiu em `RIP=0x10` antes de
`WebKit HTML submitted`, então a cópia está pronta mas ainda aguarda o
WebProcess ultrapassar o fault tardio.

### Reserva do slot TLS do executável principal (2026-09-22)

O primeiro fault do WebProcess foi reproduzido com `CR2=0x5000010000` e
`RIP=0x60000014e6`. A instrumentação do loader mostrou que o workspace filho
não tinha um mapeamento para esse endereço, embora `__tls_get_addr` o use como
o módulo dinâmico de ID 2. Quando o executável principal não possui `PT_TLS`,
o loader estava iniciando o primeiro DSO no slot zero, reutilizando o slot que
continua reservado ao módulo principal pelo ABI TLS. A reserva agora consome
sempre um `tls_stride` para o módulo 1, mesmo sem `PT_TLS`; o primeiro DSO passa
a ser mapeado em `tls_address + tls_stride`.

Validação: `zig build test` passou com `54/54 steps succeeded; 257/257 tests
passed`. Um smoke WPE de 90 s alcançou `WebKit view ready` sem o fault TLS ou
page fault anterior. Um segundo smoke de 120 s parou depois de agendar o
WebProcess, portanto a estabilidade e o primeiro frame ainda não estão
validados.

### Exportação EGL DMA-BUF (2026-09-22)

O backend EGL não usa o callback SHM: ele entrega ao cliente um
`wpe_view_backend_exportable_fdo_dmabuf_resource`, que precisa ser liberado por
`wpe_view_backend_exportable_fdo_dispatch_release_buffer`. O launcher Zig agora
implementa esse contrato, mapeia o primeiro plano DMA-BUF, copia as linhas para
o `/dev/fb0` e só então emite `WebKit first frame`. Falhas de `mmap`, descritor
ou formato continuam sem emitir sucesso.

O launcher recompilou corretamente e a suíte nativa continua verde. Os smokes
seguintes ainda foram intermitentes antes de `WebKit view ready`, portanto a
exportação DMA-BUF e o primeiro frame ainda precisam de uma execução estável.

### Fault tardio no segundo subprocesso real (2026-09-22)

Um smoke de 90 s com `WPEWebProcess` e `WPENetworkProcess` reais alcançou
`WebKit view ready`, mas não `WebKit HTML submitted`. O trace de exceções do
QEMU mostra que o segundo processo continua executando código real do allocator
(`RIP=0x600602b084`, com faults lazy resolvidos em `0xe000...`) e depois termina
em uma transferência para `RIP=0xa`/`RIP=0x9` ou em `#GP`. O fault final tem
`CPL=3`, `CS=0x23`, `RSP=0x900001d478` e `CR2` igual ao RIP inválido; portanto
não é um callback sintético nem uma falha do caminho de framebuffer. A causa
pendente é a preservação do contexto/stack no ciclo `clone(0x4111)`/exec do
subprocesso, antes de o launcher conseguir submeter o HTML.

O diagnóstico temporário foi removido após a captura. `zig build test` continua
verde; nenhum marcador de primeiro frame foi emitido.

### Verificação do frame de `clone(0x4111)` (2026-09-22)

Uma instrumentação descartável capturou o frame imediatamente antes de o
filho vfork ser agendado: `RIP=0x60300a89c9`, `R9=0x6030088270`,
`RSP=0x900001c758` e o argumento no topo da pilha em `0x900001b160`.
Esses valores são endereços válidos do processo e confirmam que o callback não
está sendo substituído por `0x9`/`0xa` na criação do frame. A mesma execução
parou antes de `WebKit HTML submitted`; portanto o defeito restante ocorre
depois da montagem do frame, durante a execução/retomada do callback ou do
contexto de exec. A instrumentação foi removida e não altera o runtime.

### `CLONE_CHILD_SETTID` no handoff do pthread (2026-09-22)

A desmontagem do `pthread_create` do musl confirmou que o TLS chega pelo
quinto argumento (`R8`) e o endereço `child_tid` pelo quarto (`R10`). O kernel
agora publica o TID no endereço `child_tid` somente quando o novo pthread é
realmente selecionado, depois que o criador devolveu o lock ao userspace; o
valor continua sendo zerado no caminho de saída. Isso evita escrever o lock
durante o retorno do `clone`. A suíte nativa permanece em `257/257`, mas o
smoke real ainda termina no segundo subprocesso em `RIP=0xa`; portanto esta
semântica adicional não fecha o gate de HTML/primeiro frame.

### Separação entre `CLONE_CHILD_SETTID` e `CLONE_CHILD_CLEARTID` (2026-09-23)

A desmontagem de `pthread_create` mostrou que `flags=0x7d0f00` usa `R10`
como endereço de `CLONE_CHILD_CLEARTID` (`__thread_list_lock`). O kernel estava
publicando o TID nesse endereço durante o primeiro handoff, embora esse bit não
implique publicação inicial; isso corrompia o lock global e podia transformar
um ponteiro de heap em `0xA000000006`. O handoff agora publica somente quando
`CLONE_CHILD_SETTID` (`0x01000000`) está realmente presente.

Após a correção, `WebKit view ready` foi observado sem o lock fault. O segundo
WebProcess ainda termina em um page fault/GP antes de `WebKit HTML submitted`;
esse é o próximo gate a investigar.

### Cache de bibliotecas WPE entre execs (2026-09-22)

O loader agora preserva uma cópia pristine dos bytes das bibliotecas WPE já
lidas pelo launcher. Subprocessos `execve` reutilizam essa cópia, em vez de
reler a biblioteca de 120 MiB setor a setor do FAT16. A cópia é feita antes
das relocations ELF (que modificam o buffer de trabalho), e o cache é liberado
quando começa um novo ciclo top-level; não há sucesso simulado nem mudança no
contrato do NVMe.

Validação em QEMU: o smoke real passou a agendar o `WPEWebProcess`, emitir
`WebKit view ready` e iniciar o segundo subprocesso antes do fault tardio
restante. `WebKit HTML submitted` e `WebKit first frame` ainda não foram
observados; o próximo diagnóstico continua sendo a retomada do segundo
subprocesso após o `clone(0x4111)`.

### Contexto de timer invalidado no exec (2026-09-23)

O ciclo de `exec` reutiliza o mesmo slot do scheduler. Antes desta correção,
o slot podia conservar um snapshot de timer da imagem anterior; uma troca
preemptiva durante o bootstrap do novo WebProcess podia restaurar a
pilha/código antigos. O caminho de imagem substituta agora instala um frame
inicial (`entry`, `stack`, `RFLAGS`) e invalida `timer_valid` antes de o slot
ser agendado.

Validação: `zig build test` passou com `54/54 steps succeeded; 257/257 tests
passed`. Em QEMU, o fault anterior de transferência para `RIP=0x9/0xa` não
reapareceu nessa execução; o WebProcess alcançou um fault posterior real de
leitura nula (`CR2=0`, `RIP=0xa00e216fd0`, código 5), ainda antes de
`WebKit HTML submitted`. Isso confirma progresso no contexto de exec, mas não
fecha o gate de HTML/primeiro frame.

### Build reproduzível do backend WPE (2026-09-23)

`tools/build-wpebackend-fdo-linux.ps1` agora passa os argumentos do Meson com
expansão correta, encontra o Ninja empacotado mesmo fora do `PATH` e normaliza
os caminhos do `pkg-config`. O link estático também inclui `gmodule-2.0` e
`zlib`, que são dependências privadas do GIO. A execução do script com `-Stage`
foi validada em uma reconstrução limpa e o artefato foi staged no sysroot.

O smoke bounded posterior alcançou `WebKit view ready`; nesta execução não
alcançou `WebKit HTML submitted`, portanto o gate do primeiro frame permanece
aberto. QEMU foi encerrado pelo runner ao fim do timeout.

### `recvmsg` com `MSG_CMSG_CLOEXEC` (2026-09-23)

O caminho Linux de `recvmsg(2)` agora aceita `MSG_CMSG_CLOEXEC`, que já era
consumido pela rotina real de entrega de `SCM_RIGHTS`. Antes, a validação
rejeitava a flag com `EINVAL` antes de materializar os descritores recebidos,
incompatível com o contrato usado pelo GLib/WPE no process-pool. A correção
foi compilada e a suíte `zig build test` passou; o smoke WPE ainda não fecha o
gate de `WebKit HTML submitted`/primeiro frame.

O smoke posterior ao commit `c4d7960a` confirmou a sequência real
`WebKit view ready` → `WebKit HTML submitted` → `WebKit GLib loop complete`
em QEMU. O callback de exportação ainda não foi observado; uma execução
também registrou page fault posterior no WebProcess. O gate de primeiro frame
continua aberto e não há fallback visual sintético mantido.

## Referências upstream

### Threads adiadas limitadas ao workspace (2026-09-23)

O scheduler mantinha uma fila global de threads recém-criadas. Durante um tick
de preempção, essa fila podia selecionar uma thread `.thread` de outro
workspace enquanto um processo WPE ainda inicializava, trocando o address space
no meio do bootstrap. A seleção cooperativa e a seleção pelo timer agora
exigem o mesmo `workspace_id`, ignoram o slot atual e deixam process children
no caminho separado de `deferred_process_children`.

Na mesma revisão, wakeups pendentes de `wait4` e de I/O passaram a exigir o
workspace atual; somente o handoff explícito de `vfork/exec` pode atravessar
essa fronteira.

`zig build test` continua verde. O smoke real ainda alcança `WebKit HTML
submitted` em execuções estáveis, mas não observou `WebKit first frame`; o
WebProcess continua apresentando faults tardios intermitentes. Portanto o
gate de compositor/frame permanece aberto.

### Base física da stack em forks aninhados (2026-09-23)

`cloneWritableRange` já criava páginas privadas para a stack de um workspace
filho, mas `stack_physical` continuava registrando a base física do pai. Um
segundo `fork/exec` (o padrão do process-pool WPE) copiava então a stack errada.
O loader agora atualiza `stack_physical` para a primeira página realmente
alocada para o filho.

Validação: `zig build test` passou. O smoke real continua alcançando
`WebKit HTML submitted`; a falha posterior deixou de ser consistentemente um
salto para `RIP=0/1` e também apareceu como `#UD` em código JIT anônimo. O
primeiro frame ainda não foi observado.

### Preservação SIMD no dispatcher de syscalls (2026-09-23)

O dispatcher de syscalls executa código Zig entre a entrada `syscall` e
`user_thread_resume`. Esse caminho podia alterar registradores XMM do thread
interrompido antes que o scheduler salvasse o contexto, especialmente durante
`mmap`, `poll` e futex usados pelo WPE. A entrada agora preserva o estado
FXSAVE/FXRSTOR ao redor do dispatcher, mantendo a ABI SIMD do userspace antes
de retomar a seleção de threads.

O smoke continua chegando a `WebKit HTML submitted`, mas ainda não produziu
`WebKit first frame`; portanto esta correção é uma proteção de contexto, não
uma conclusão falsa do gate do compositor.

### Não promover faults de dados com CR2 nulo (2026-09-23)

Uma execução instrumentada mostrou `CR2=0`, `code=5` e `RIP` dentro da arena
anônima. Esse código é um fault de acesso de dados em modo usuário, não um
fault de instruction-fetch. O tratamento anterior usava qualquer `CR2=0` como
fallback de NX e promovia a página do RIP para executável, mascarando o acesso
nulo e corrompendo o fluxo posterior. O fallback agora só é usado quando o bit
de instruction-fetch (`code & 0x10`) está presente.

Validação: `zig build -j1 test` passou; o smoke alcança `WebKit HTML submitted`
e `WebKit GLib loop complete`. O primeiro frame ainda não foi observado.

### Estado após a correção do fault (2026-09-23)

O smoke repetido confirma que o pipeline avança por `WebKit view ready`,
`WebKit HTML submitted` e `WebKit GLib loop complete`. O callback de SHM/DMA-BUF
continua sem emitir `WebKit first frame`. Depois do loop há um fault tardio no
workspace do launcher (`CR2=0`, código de dados ou proteção geral), com RIP em
uma região anônima zerada; isso indica corrupção/ponteiro inválido no caminho
de saída ou em um processo auxiliar, não um sucesso de compositor. O gate de
primeiro frame permanece aberto e nenhuma etapa de desktop foi promovida.

### Surface bridge ainda não registrada (2026-09-23)

A implementação upstream do FDO só chama o cliente de exportação depois que o
WebProcess registra uma surface pelo bridge Wayland; `dispatch_frame_complete`
apenas libera os callbacks já associados à surface. Os smokes atuais não
produzem `WebKit SHM callback` nem `WebKit DMA-BUF callback`, apesar de
`WebKit HTML submitted`. Portanto o próximo diagnóstico deve seguir o socket
renderer-host e o registro bridge/surface entre WebProcess e o backend, antes
de alterar o paint ou o framebuffer.

### Smoke longo confirma o ponto do bloqueio (2026-09-23)

Uma execução delimitada de 150 s (`smoke-3923cca55c174be3a5d324df7886f19e`) voltou a
produzir a sequência real `WebKit view ready` → `WebKit HTML submitted` →
`WebKit GLib loop complete`. Não houve `WebKit SHM callback`, `WebKit DMA-BUF
callback` nem registro observável de surface; ao destruir o exportable, o
launcher recebeu um page fault de dados (`CR2=0`, `code=5`) em uma região
anônima. Instrumentação temporária de `SCM_RIGHTS` não registrou erro de parse
ou de materialização de alias. O gate permanece aberto: a próxima alteração
deve fazer o renderer-host/Wayland concluir `wpe_bridge_connect` e
`RegisterSurface`, além de corrigir o caminho de saída que ainda falha no
teardown.

### Acknowledge do buffer EGL genérico (2026-09-23)

O callback `export_buffer_resource` do launcher estava vazio. Isso deixava um
`wl_buffer` EGL retido e não chamava `dispatch_frame_complete`; o launcher agora
libera o recurso e confirma o frame nesse caminho. O smoke de 120 s passou pela
mesma sequência anterior e não invocou o callback, confirmando que a surface
ainda não é criada; portanto a mudança não promove o gate de primeiro frame.

### Socketpair local full-duplex (2026-09-23)

O IPC local do kernel criava os dois extremos de
`socketpair(AF_UNIX, SOCK_STREAM/SEQPACKET)` sem permissões de leitura e
escrita. Isso fazia os canais de controle do WebKit e do renderer-host
falharem com `EBADF` antes de o backend Wayland inicializar. Os quatro
sentidos agora são marcados como válidos, preservando a semântica
full-duplex do Linux.

Validação: `zig build -j1 test` passou. No smoke com o backend FDO
instrumentado, o segundo `CSOS WPE WebProcess scheduled` passou a ser
observado sem o fault imediato anterior; o registro de `wpe_bridge` e o
primeiro frame ainda precisam ser confirmados em uma execução estável.

### Identificação de instruction-fetch em faults anônimos (2026-09-23)

O log de exceções do QEMU mostrou faults NX reais (`error=0x15`) em páginas
da arena JIT, enquanto o dispatcher do CSOS recebia a forma legada `code=5`
após faults aninhados. O handler agora considera também a assinatura segura
`CR2 == RIP` dentro da arena `mmap`: a primeira página é criada executável e
uma página já mapeada é promovida com `protectUserPage`. Isso evita que o
WebKit tente executar uma página anônima ainda marcada NX.

Validação: `zig build -j1 test` passou e o smoke voltou a alcançar os dois
processos WebKit, `WebKit view ready`, `WebKit HTML submitted` e
`WebKit GLib loop complete`. O callback de exportação ainda não ocorreu e o
primeiro frame continua aberto; o próximo bloqueio observado é um fault tardio
de ponteiro/teardown (`RIP=1`), separado do fault NX corrigido aqui.

### CLONE_VFORK sem cópia da arena WebKit (2026-09-23)

O `clone(0x4111)` usado pelo WPE é `CLONE_VFORK`: o processo pai fica
suspenso até `execve` ou `_exit`. O workspace clone, porém, copiava páginas
privadas da stack, `brk` e da arena anônima antes do `exec`, causando atrasos e
timeouts no segundo WebProcess. O hook agora identifica o vfork, preserva as
folhas compartilhadas em tabelas clonadas e marca o workspace como
`borrowed_owned`; o `exec` destrói essas tabelas antes de carregar a imagem
substituta, sem liberar páginas pertencentes ao pai.

Validação: `zig build -j1 test` passou. Um smoke de 180 s chegou de forma
estável a dois `CSOS WPE WebProcess scheduled`, `WebKit view ready`,
`WebKit HTML submitted` e `WebKit GLib loop complete`. O callback de frame
ainda não foi observado, mas o bloqueio de cópia/timeout do vfork foi removido.

### Ordem de destruição do view/backend: bloqueio GLib (2026-09-23)

Foi testada a liberação explícita do `WebKitWebView` com `g_object_unref` antes
do exportable FDO. No runtime atual isso produz `g_datalist_id_set_data_full:
assertion 'key_id > 0' failed` e um fault posterior; a chamada foi removida e
não é tratada como correção. A ordem de ownership continua sendo um bloqueio
de teardown, mas exige primeiro corrigir a inicialização/ABI do GObject no
runtime CSOS. O primeiro frame permanece não validado.

- [Arquitetura WPE](https://wpewebkit.org/about/architecture.html): backend de
  apresentação desacoplado e encaminhamento de input.
- [Ports upstream](https://docs.webkit.org/Ports/Introduction.html): WPE e
  JSCOnly são ports diferentes; JSCOnly não oferece layout HTML/CSS.
- [Roteiro histórico de portabilidade](https://trac.webkit.org/wiki/SuccessfulPortHowTo):
  JavaScriptCore antes de WebCore. Usar apenas como orientação, não como lista
  atual e completa de dependências.
