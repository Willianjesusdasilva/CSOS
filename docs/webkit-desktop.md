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

**Resultado atual: FAIL, `pthread_create errno=11`.** A execução de diagnóstico
esperou explicitamente o marcador FAIL e encerrou QEMU. O exit 0 desse runner
significa apenas que observou a falha esperada, não que o gate passou. O programa
retornou 21 e o kernel registrou `ProcessFailed`.
Log local: `zig-out/smoke-e66add5667ae47a8a04e80c08d247489.serial.log`.

A inspeção do dispatcher confirma ausência de `clone` (56) e `clone3` (435).
O `futex` atual nunca coloca um waiter para dormir; `gettid` é fixo em 1.
O scheduler de threads do kernel não basta: `process.runImage` tem contexto
ativo e bookkeeping globais e executa uma entrada userspace por vez. Próxima
implementação necessária: contextos de threads userspace (registradores/TLS/
stack/TID), clone compartilhando address space, saída individual, clear_tid e
espera/acordar futex. Não corrigir isso retornando sucesso fictício.

Upstream fixado para investigação: **WPE WebKit 2.52.6**, commit
`3bcefb149bd7e5645d18c3f0b9abd515b274649f` (tag anotada resolvida).
`tools/fetch-webkit.ps1` prepara esse checkout sem descartar mudanças locais.
A compilação do engine e sua execução ainda não foram realizadas.

## Referências upstream

- [Arquitetura WPE](https://wpewebkit.org/about/architecture.html): backend de
  apresentação desacoplado e encaminhamento de input.
- [Ports upstream](https://docs.webkit.org/Ports/Introduction.html): WPE e
  JSCOnly são ports diferentes; JSCOnly não oferece layout HTML/CSS.
- [Roteiro histórico de portabilidade](https://trac.webkit.org/wiki/SuccessfulPortHowTo):
  JavaScriptCore antes de WebCore. Usar apenas como orientação, não como lista
  atual e completa de dependências.
