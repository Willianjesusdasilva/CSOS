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
A compilação do engine e sua execução ainda não foram realizadas.

## WPE platform bootstrap

`tools/build-libwpe-linux.ps1` compila o `libwpe` upstream 1.16.3 para o
sysroot musl com Zig. O gate confirmou os headers EGL/KHR exigidos pelo
backend WPE; ainda falta compilar o WebKit/WPE e ligar o backend CSOS.

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

O build ainda não terminou: o host Windows não permite symlinks sem privilégio
de Developer Mode, e a cópia de headers gerados provoca duplicação de alguns
headers sem include guard. A solução definitiva é executar a geração com
symlinks habilitados (ou habilitar Developer Mode no host); não é um bloqueio
de dependência do engine. O próximo gate é completar a compilação e então
ligar um launcher WPE headless ao mailbox/IPC do CSOS.

## Referências upstream

- [Arquitetura WPE](https://wpewebkit.org/about/architecture.html): backend de
  apresentação desacoplado e encaminhamento de input.
- [Ports upstream](https://docs.webkit.org/Ports/Introduction.html): WPE e
  JSCOnly são ports diferentes; JSCOnly não oferece layout HTML/CSS.
- [Roteiro histórico de portabilidade](https://trac.webkit.org/wiki/SuccessfulPortHowTo):
  JavaScriptCore antes de WebCore. Usar apenas como orientação, não como lista
  atual e completa de dependências.
