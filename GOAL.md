# CSOS — objetivo e ordem de execução

## Objetivo

Construir um sistema operacional x86-64 em Zig, funcional em hardware real e otimizado para executar Steam e Counter-Strike 2 com baixo overhead, frametime consistente e baixa latência.

O sistema operacional vem primeiro. Steam, Steam Runtime e CS2 são as últimas etapas e não devem antecipar nem bloquear boot, memória, processos, armazenamento, entrada, rede, áudio, display, GPU, Vulkan, estabilidade e recuperação.

## Regras

- Priorizar `funciona > simples > rápido > bonito`.
- Reutilizar componentes maduros como Mesa, RADV, Nouveau/NVK e, quando necessário e legalmente compatível, componentes oficiais redistribuíveis.
- Não reimplementar integralmente drivers modernos AMD ou NVIDIA em Zig antes do primeiro frame Vulkan.
- Não anunciar suporte por mera detecção PCI, framebuffer ou código testado somente no host.
- Não tentar alterar, contornar ou enganar VAC.
- Não deixar QEMU aberto sem motivo; encerrá-lo após cada validação que o iniciar.
- Só finalizar este GOAL quando o projeto completo satisfizer a Definition of Done.

## GPU AMD e NVIDIA

AMD Radeon e NVIDIA GeForce são requisitos oficiais, não alternativas opcionais.
O produto final deve inicializar e executar Vulkan em uma máquina somente com
GPU NVIDIA, sem depender da presença ou inicialização de hardware AMD.

O instalador deve detectar e selecionar automaticamente um backend suportado
para a GPU presente. AMD e NVIDIA devem funcionar de forma independente; uma
máquina de um fabricante não pode exigir uma GPU auxiliar do outro. Em sistemas
híbridos, a escolha da GPU de display/jogo deve ser explícita e registrada em
`hardware.csc`.

A ordem interna evita duas stacks incompletas em paralelo:

```text
DRM/KMS, memória, filas e sincronização compartilhados
↓
AMD Radeon + AMDGPU/RADV + triângulo Vulkan em hardware real
↓
NVIDIA GeForce + Nouveau/NVK ou stack compatível + triângulo Vulkan em hardware real
```

AMD permanece como primeiro backend de referência. O trabalho NVIDIA começa depois do primeiro triângulo AMD/RADV real. M14 só termina quando ao menos uma família explicitamente suportada de cada fabricante comprovar inicialização, memória, filas, sincronização e triângulo Vulkan em hardware real.

Estado do requisito NVIDIA em 2026-09-04: **0% validado em hardware e ainda
pendente**. Há infraestrutura genérica que poderá ser reutilizada, mas ela não
deve ser contabilizada como backend NVIDIA até uma GeForce executar o caminho
completo. A próxima frente continua sendo concluir AMD/RADV; imediatamente após
o triângulo AMD real, NVIDIA passa a ser o bloqueio principal de M14. Steam
Runtime, Steam e CS2 permanecem posteriores à conclusão funcional do SO e dos
dois backends gráficos.

Critérios de aceitação específicos para NVIDIA (ainda pendentes):

- [ ] Registrar a GeForce validada, PCI ID, família, firmware, driver e backend Vulkan utilizados.
- [ ] Inicializar o instalador e o SO em máquina somente NVIDIA, sem dependência de AMD.
- [ ] Validar memória GPU, filas e sincronização, além de display básico.
- [ ] Executar um triângulo Vulkan real e reproduzível nessa GeForce.
- [ ] Selecionar e persistir o backend correto em `hardware.csc`.
- [ ] Publicar uma matriz NVIDIA por modelo/PCI ID, distinguindo validado, experimental e não suportado, com procedimento e evidências de validação reproduzíveis.

Esses critérios integram M14 e não devem ser adiados para depois de Steam/CS2.
Adicionar o requisito à documentação não significa que o driver já esteja
implementado ou validado, nem aumenta a porcentagem concluída do projeto.

## Ordem das milestones

- [x] **M0–M13 — fundações do SO:** build, boot, memória, CPU/SMP, scheduler, userspace, ABI Linux inicial, BusyBox, PCIe, NVMe, filesystem, USB/xHCI, rede e áudio possuem fundações implementadas; integração e validação final ainda continuam.
- [ ] **M14 — GPU AMD/NVIDIA + Vulkan:** parcial. A preparação AMD GFX11, `AMDGPU_INFO_DEV_INFO`, `AMDGPU_INFO_MEMORY`, a leitura restrita do `GB_ADDR_CONFIG` físico e as consultas obrigatórias de firmware ME/MEC/PFP possuem implementação e testes de host. As versões vêm dos blobs GFX11 selecionados e validados. O contrato GPUVA já faz o libdrm derivar `address32_hi = 0`, e DRM 3.54 só é anunciado quando os perfis físico/memória/firmware, allocator VRAM e command submission estão instalados; `ACCEL_WORKING` exige perfis válidos e um callback de saúde instalado após o teste PM4 físico; retorna zero sem esse callback ou quando a fila/GART fica indisponível. O bit permite iniciar libdrm/RADV para validação, não certifica Vulkan. GEM aceita placement real na VRAM visível, mantém endereços CPU/MC separados, instala PTEs GPUVA sem atributos de memória de sistema, atualiza uso/capacidade das heaps VRAM e GTT e aplica semântica explícita aos flags de criação usados pelo RADV. `AMDGPU_CS` aceita a BO list inline e até 192 IBs GFX do RADV atual, com validação individual, residência, BOs `VM_ALWAYS_VALID` e uma única conclusão física. Capacidade PCIe combinada, tipo/largura de VRAM via ATOM, clocks e snapshots físicos de CUs/RBs/TCC/UMCs ativos também estão cobertos. A identidade PCI Linux compartilhada agora publica major/minor dos nós DRM, `uevent`, IDs PCI reais e o vínculo de subsistema exigido por `drmGetDevice2`, com `readlink`/`readlinkat`; testes de host e Ring 3 comprovam `card0`, `renderD128` e os arquivos sysfs pela ABI Linux. VRAM não visível ainda não é alocável. Shadow/CSA/userq permanecem corretamente desabilitados; validação do libdrm no userspace real, execução Radeon real e triângulo RADV ainda faltam. Depois do triângulo AMD, NVIDIA/NVK ou stack compatível deve funcionar de forma independente em uma máquina somente NVIDIA e também exige validação real de inicialização, memória, filas, sincronização e triângulo Vulkan.
- [ ] **M15 — SDL:** vídeo, input e áudio sobre o caminho funcional do SO.
- [ ] **M16 — hardware discovery/autotune:** detectar hardware e produzir `/system/config/hardware.csc`.
- [ ] **M17 — otimização para jogos:** scheduler, IRQ, input, rede, NVMe, áudio, GAME e MATCH medidos contra baseline.
- [ ] **M18–M19 — ciclo de processos e standby:** freeze, reclaim seguro e retomada.
- [ ] **M20–M23 — interface do sistema:** runtime HTML/CSS/Jinja, actions, Alt+Tab e UI dinâmica.
- [ ] **M24–M26 — aceleração e autotune de GPU do sistema:** somente onde houver ganho medido; desativado por padrão em MATCH.
- [ ] **M27 — Steam Runtime:** corrigir a ABI necessária somente após o SO estar funcional.
- [ ] **M28 — Steam:** abrir, autenticar, exibir biblioteca e baixar jogos.
- [ ] **M29 — CS2:** iniciar, abrir menu, jogar offline, entrar em servidor e concluir uma partida.
- [ ] **M30 — integração final:** validar todo o fluxo, estabilidade e performance.

## Progresso atual

Snapshot em 2026-09-04, ponderado por funcionalidade real:

```text
concluído: aproximadamente 40%
restante:  aproximadamente 60%
```

Esta porcentagem não é uma contagem simples de milestones. M0–M13 têm bases relevantes, mas M14 ainda não possui triângulos Vulkan validados em AMD e NVIDIA, e M15–M30 permanecem majoritariamente pendentes. Código preparatório ou teste no host não equivale a hardware funcional.

## Próxima rota

A descoberta DRM ganhou um gate adicional: antes de criar a instância, o
probe chama `drmGetDevices2(0, NULL, 0)` e exige pelo menos um dispositivo DRM.
O boot tardio falhou com `ProcessFailed` em
`zig-out/smoke-3386096300db48009aefe3d6b5a97495.serial.log`. A contagem Vulkan
zero anterior não comprova descoberta DRM correta. Próximo diagnóstico:
confirmar status 5 do probe e inspecionar o retorno libdrm e seus acessos a
diretórios/atributos. O QEMU foi encerrado. A inicialização/instância já
validadas não equivalem a GPU detectada pelo caminho completo.

`-Dradv-probe-after-gpu=true` agora permite executar o mesmo probe e seus
gates após a preparação gráfica, sem habilitar automaticamente gates MMIO.
Isso evita enumerar prematuramente a Radeon no futuro teste físico. O caminho
tardio passou em QEMU no log
`zig-out/smoke-8c713689f7994df0b47e618920eeb07b.serial.log`, incluindo
instância, enumeração e recuperação de páginas. O runner encerrou o QEMU.

O probe agora executa `vkEnumeratePhysicalDevices` e registra a contagem
retornada. A enumeração e o gate final passaram no boot limitado registrado em
`zig-out/smoke-0c5bb9c212584237b9ff488d5b423533.serial.log`, com criação e
destruição da instância e recuperação de páginas. Essa execução em QEMU não
substitui a descoberta de uma Radeon física nem valida criação de dispositivo,
filas ou triângulo. O QEMU foi encerrado automaticamente.

Integração de inicialização musl validada: o loader encontra
`csos_musl_bootstrap` na libc e transmite por auxv privado os descritores
PT_TLS com a numeração DTPMOD64 preservada. O intérprete chama o bootstrap
antes dos construtores. O boot limitado passou em
`zig-out/smoke-cca7d71cbfc446b2a9d8c59ec7751334.serial.log`: cookie do
construtor, negociação ICD, `vkCreateInstance` e `vkDestroyInstance` tiveram
sucesso, assim como o gate de recuperação de páginas. Isso comprova criação
de instância headless no QEMU; enumeração/dispositivo Radeon, filas reais e
triângulos AMD/NVIDIA permanecem pendentes. O QEMU foi encerrado.

Foi compilada a entrada privada `csos_musl_bootstrap` em
`tools/musl-csos-bootstrap.c`, ligada à musl com seus headers internos fixados.
Ela valida descritores TLS limitados, preserva slots DTPMOD64, prepara a lista
TLS e usa `__copy_tls`, `__init_tp` e `__init_libc` oficiais. O link auditado
produziu 3.512.720 bytes e exportou essa entrada. Ainda não está conectada ao
intérprete nem foi executada em Ring 3; o staging foi preservado. Próximo passo:
transmitir descritores de PT_TLS e a entrada pelo contrato do loader, invocá-la
antes dos construtores e validar retorno, TLS e recuperação de páginas.

Recompilação limpa concluída: 1.347/1.347 objetos upstream foram recompilados,
o relink passou na auditoria e a libc de 3.509.112 bytes foi instalada no
staging. SHA-256:
`8c275c3e6dfd669b1574c4dd413be3fa20c7ac2fee9350734cf084e00a282604`.
O checkout musl permanece limpo. Isso elimina a dependência dos experimentos
de edição de visibilidade. O novo runtime ainda precisa repetir a validação
Ring 3 após a integração de auxv/thread pointer/DTV antes dos construtores.

O script `build-musl-runtime.ps1` passou a exigir o checkout musl fixado e
limpo, recompilar os objetos upstream, executar link/auditoria e copiar para
staging somente após sucesso. Ele exige a configuração out-of-tree existente;
a preparação automática dessa configuração ainda falta. Sua sintaxe PowerShell
foi validada; a recompilação já iniciada deve terminar antes de testar o fluxo
completo para evitar dois builds escrevendo nos mesmos objetos.

`audit-musl-runtime.py` agora integra o link da musl e exige exports essenciais
apontando para bytes em segmentos executáveis, SONAME, ausência de dependências
externas/RPATH/TEXTREL e relocations suportadas. A auditoria aceitou o ELF real
anterior e rejeitou explicitamente a DSO de stubs em `strlen`. A recompilação
dos objetos upstream continua em andamento; falta auditar o novo relink.

A reprodução sem edição de símbolos está sendo feita por
`tools/rebuild-musl-objects.py`: ele extrai os comandos de compilação do Makefile
upstream e recompila todos os objetos, com paralelismo limitado. Os experimentos
`promote-musl-exports.py` e `musl-exports.map` foram removidos. A conclusão dessa
recompilação e o relink ainda precisam ser observados antes de declarar o build
limpo validado.

A leitura da musl upstream confirmou que `ldso/dynlink.c` fornece um
`__init_tls` vazio: o carregador musl normalmente prepara o thread pointer e
DTV antes de `__libc_start_main`. Assim, chamar esse entrypoint isoladamente
não inicializa corretamente o TLS no carregador CSOS. A integração deve
preparar o estado completo antes dos construtores, incluindo ambiente, auxv,
thread pointer e os módulos TLS carregados. O intérprete CSOS agora passa
`argc`, `argv` e `envp` aos construtores, e o probe verifica esse contrato.
`DT_INIT` não executável volta a ser rejeitado: a exceção temporária para os
stubs foi retirada. A validação Vulkan segue pendente da inicialização musl.

O `_start` C do probe tinha alinhamento SysV incorreto: o código emitia
`movaps` numa stack desalinhada por não existir endereço de retorno na entrada
ELF. Uma entrada assembly agora alinha RSP e chama `probe_main`. O boot avançou
até um page fault em `libc.so + 0x63c90`, identificado por addr2line como
`get_random_secret` em `mallocng/glue.h:47`, acesso ao endereço zero. Isso
direciona o próximo trabalho à inicialização da libc e de seu auxv antes de
malloc/Vulkan. Log: `zig-out/smoke-3fa6eea3cac645e79f04df6e1dab6031.serial.log`.
QEMU encerrado ao fim do prazo de 30 segundos; instância Vulkan ainda pendente.

O probe foi ampliado para resolver `vkCreateInstance` pelo ICD, criar uma
instância e chamar `vkDestroyInstance`, usando os headers Vulkan do Mesa fixado.
O build passou, mas o boot limitado de 30 segundos terminou em exceção de
proteção geral (marcador `G` do vetor 13), após o intérprete e antes do marcador
de sucesso. Log: `zig-out/smoke-477a716e5073490babe72d2e79f593a3.serial.log`.
O QEMU foi encerrado. Próximo diagnóstico: capturar RIP/estado da exceção e
verificar alinhamento da stack e inicialização libc/TLS nesse caminho. A criação
de instância continua não validada; o sucesso anterior cobre apenas negociação
e construtores.

Validação em 2026-09-05: a musl PIC de 3.509.208 bytes passou no probe RADV
em Ring 3 com os construtores habilitados. Uma segunda execução adicionou ao
executável um construtor que grava um cookie, verificado antes da negociação
do ICD; o marcador `RADV dynamic loader ready` passou novamente. Os gates
incluem carregamento de cinco objetos e recuperação das páginas. Ambos os
boots foram limitados e encerrados. Isso ainda não valida `vkCreateInstance`,
dispositivo Vulkan ou hardware AMD/NVIDIA. Permanecem a reprodução do build
sem as alterações experimentais de visibilidade e o avanço para criação de
instância Vulkan.

O link da musl PIC avançou: `link-musl-shared.py` compila `mulsc3`, `muldc3`
e `mulxc3` do compiler-rt fixado, exige sua revisão exata e incorpora os objetos
com visibilidade interna. Sem `-lgcc`/`-lgcc_eh`, o link concluiu e passou a
exportar `strlen` e `memcpy`, com SONAME `libc.so` e sem `DT_NEEDED` externo.
Esse novo artefato ainda precisa repetir o probe Ring 3 antes de ser considerado
runtime operacional. O problema de exports observado no link anterior foi
resolvido nessa combinação; as tentativas anteriores de editar visibilidade
dos objetos precisam ser removidas do fluxo reproduzível e revalidadas.

Atualização em 2026-09-05: musl v1.2.5 oficial foi obtida no commit
`0784374d561435f7c787a555aeab8ede699ed298` e seus objetos PIC foram compilados.
O link usa response file para respeitar o limite de comandos do Windows.
A inspeção da linha efetiva revelou que `-lgcc_eh` introduzia libunwind e a
libc de stubs do Zig. Sem essas dependências, faltam as rotinas compiler-rt
`__mulsc3`, `__muldc3` e `__mulxc3`; o runtime ainda não está validado.
O script antigo de staging foi desabilitado para não reinstalar os stubs.
Próximo passo: fornecer essas rotinas PIC, auditar exports públicos e só então
repetir o probe RADV limitado. A causa completa de `strlen` oculto permanece
em investigação; as tentativas de promover símbolos não provaram solução.

Regressão de recuperação Ring 3 corrigida: iterações por valor da tabela GPUVA
excediam a stack de syscalls de 64 KiB e corrompiam `drm_pages`. As iterações
agora usam referências; o pico instrumentado caiu de 170.504 para 11.920 bytes.
Os diagnósticos e as stacks experimentais foram removidos. `zig build test`
passou 10/10 testes; boot normal e `-Ddrm-amdgpu-abi-test=true` passaram sem
instrumentação, exigindo `CSOS M17 process reclaim ready` e igualdade de páginas.
Detalhes e logs em `docs/radv-bringup-audit.md`. Isso não comprova Vulkan real.

O alinhamento GEM de 2 MiB exigido pelo ring GFX11 foi implementado nos caminhos
VRAM e GTT. Testes de host cobrem allocator físico, GEM VRAM e, em Windows com
memória baixa, GEM GTT/fallback por VRAM esgotada. GEM GTT alinhado também passou
em Ring 3, assim como VRAM|GTT com fallback quando o backend VRAM está ausente.
Ainda faltam VRAM esgotada em Ring 3 e a alocação pelo RADV real, conforme
`docs/radv-bringup-audit.md`. Isso não equivale a execução da stack real.

O libdrm original já executa `drmGetVersion` e `drmGetDevice2` em Ring 3 e
identifica a GPU QEMU `1234:1111`, com recuperação de memória validada. Foram
corrigidos o comando ioctl estendido com sinal, hints de mmap e a stack de
userspace (128 KiB, distinta da stack de syscalls). Isso não valida AMDGPU/RADV.

O probe também passou após a preparação gráfica, até `CSOS console shell ready`,
com recuperação de páginas. Essa validação corrigiu um acesso incondicional ao
IP discovery AMD no caminho QEMU. `-Dlibdrm-probe-after-gpu=true` seleciona o
ponto tardio sem habilitar gates MMIO; hardware AMD/NVIDIA real segue pendente.

Regressões adicionais comprovadas: render node reconhecido pelo libdrm original,
duplicação/flags de descritor e mmap GEM pelo render node. O teste AMDGPU exige
55 ioctls, quatro mmaps e cinco objetos liberados, incluindo rejeição de mmap
executável, privado e fora do BO. A validação consolidada está em
`tools/test-system.ps1`: testes de host e dois boots limitados até o console.
Ela não substitui libdrm_amdgpu/RADV operacional nem teste físico AMD/NVIDIA.

As três operações de mapeamento (`mmap`, `mprotect` e `munmap`) rejeitam
comprimentos que transbordariam o arredondamento para páginas. A regressão
Ring 3 verifica os erros e preserva leitura/escrita do BO após as rejeições de
proteção e unmap. A suíte consolidada passou novamente (10 testes de host e
dois boots até o console); isso é robustez da base do SO, não avanço de Vulkan.

O probe libdrm_amdgpu agora inclui, após inicialização bem-sucedida, alocação GTT
com alinhamento solicitado de 2 MiB, leitura/escrita CPU, reserva/mapeamento
GPUVA e liberação dos recursos pela biblioteca original. O build passou;
esse novo caminho ainda não executou em Radeon. QEMU continua sendo rejeitado
por DRM 1.0, sem simular hardware AMD para ultrapassar a inicialização.

A preparação da stack real também precisa validar o carregamento ELF: hoje o
loader só aceita `/lib/ld-csos.so` e até quatro objetos compartilhados. Os
probes estáticos não comprovam runtime dinâmico Linux. Antes de ampliar a ABI,
construir a stack escolhida e inventariar seus requisitos reais de intérprete,
bibliotecas e relocations. A syscall 204 vista no probe tem fallback na consulta
musl de CPUs e não é a causa da rejeição DRM observada.

O checkout Mesa completo da revisão auditada `9311c93dbef6b87a30bc282c3683efefc5f26f77`
agora está em `.tools/mesa-src`, sem alterações. As ferramentas Python de build
estão isoladas e fixadas em `tools/mesa-build-requirements.txt`. Configuração,
compilação Linux do RADV e inventário ELF continuam pendentes; obter os fontes
não conta como suporte gráfico funcional.

O perfil de cross-build em `tools/configure-radv.ps1` separa geradores Windows
de bibliotecas Linux x86-64 musl. A configuração reconheceu C/C++ de ambos os
targets e parou por ausência de `glslangValidator`, exigido pelo RADV dessa
revisão. Resolver essa ferramenta nativa é o próximo passo de build; libdrm
Linux e outras dependências ainda precisam ser configuradas. O perfil inicial
sem WSI/display não substitui o caminho final de apresentação Vulkan.

O requisito glslang foi resolvido com o release oficial 16.5.0, isolado em
`.tools` e verificado por SHA-256 via `tools/prepare-glslang.ps1`. Meson agora
encontra o compilador de shaders e para na descoberta de libdrm: falta
pkg-config para o target Linux e as bibliotecas target instaladas. O build
RADV continua pendente; nenhuma validação física foi substituída.

libdrm e libdrm_amdgpu 2.4.134 agora foram compilados como bibliotecas ELF64
x86-64 e instalados no staging Linux via `tools/build-libdrm-linux.ps1`.
pkgconf nativo encontra ambos com versão e caminhos corretos. Os SONAMEs são
`libdrm.so.2` e `libdrm_amdgpu.so.1`; ambos exigem `libc.so`. Isso ainda não
comprova carregamento no CSOS. Próxima etapa: repetir a configuração RADV com
essas dependências, sem usar o launcher Python defeituoso do pkg-config.

A nova configuração RADV já reconheceu libdrm e libdrm_amdgpu 2.4.134 no
staging e avançou às sondagens do compilador. Os testes upstream
`core-symbols-check` e `amdgpu-symbols-check` passaram (2/2) e agora fazem parte
do script de build libdrm. Configuração completa e compilação RADV ainda não
foram comprovadas.

zlib 1.3.1 upstream foi compilada com Zig para Linux x86-64 e instalada no
mesmo staging por `tools/build-zlib-linux.ps1`. O script opera em cópia gerada
porque o CMake upstream renomeia `zconf.h`, preserva o checkout fixado e exige
ELF no resultado. pkgconf retorna 1.3.1; SONAME `libz.so.1`, dependência
`libc.so`. A configuração RADV anterior terminou exatamente por ausência de
zlib; a repetição com zlib está em andamento e ainda não comprova build.

Com zlib presente, o perfil headless RADV configurou 99 targets e concluiu os
770 passos. `libvulkan_radeon.so` é ELF64 x86-64, tem SONAME correto, depende
somente de `libdrm_amdgpu.so.1`, `libz.so.1`, `libdrm.so.2` e `libc.so`, e
exporta apenas os três entrypoints ICD esperados. O wrapper preserva o version
script GNU e remove do ELF apenas o RUNPATH de staging Windows que o Meson
cross-host tentava inserir. A detecção AVX2 não foi desativada: o símbolo
`__cpu_model` veio do `cpu_model/x86.c` oficial do compiler-rt 21.1.0, compilado
como PIC pela revisão fixada `3623fe661ae35c6c80ac221f14d85be76aa870f1`.
Isto comprova o build real do driver, não seu carregamento no CSOS, command
submission em Radeon nem triângulo Vulkan físico; o progresso global permanece
em aproximadamente 40% concluído e 60% restante.

O primeiro inventário do ELF mostra que os tipos de relocation do RADV já são
os quatro tratados pelo loader (`RELATIVE`, `JUMP_SLOT`, `GLOB_DAT` e
`DTPMOD64`). O bloqueio imediato é capacidade: os quatro segmentos LOAD do
driver ocupam 4.423 páginas, contra `max_mappings = 512`, e as tabelas atuais
ficam na stack. A correção deve mover o bookkeeping para armazenamento escalável
e contabilizar também libdrm, zlib e libc; apenas aumentar o array local não é
aceitável. Depois ainda será necessário carregar dependências reais do
filesystem e executar `DT_INIT_ARRAY` antes de tentar iniciar o ICD.

O limite imediato de mappings foi removido sem ampliar a stack: o workspace
serializado do loader agora mantém 8.192 mappings e ranges de propriedade em
BSS, deixando espaço para o RADV e suas dependências diretas. Isso deverá virar
estado por processo quando houver `exec` concorrente. A suíte consolidada passou
10/10 testes de host e os dois boots QEMU limitados até o console; ambos foram
encerrados automaticamente. O teste ainda não carrega o RADV e não altera a
estimativa global de 40%/60%.

O inventário agora é um gate automático de `build-radv.ps1`: arquitetura,
SONAME, NEEDED, exports, ausência de RUNPATH, runtime de CPU, relocations e
capacidade LOAD são verificados após cada build. Mesmo sem debug, o driver mede
19.084.448 bytes, acima do limite atual de 16 MiB por `.so`; strip completo
chega a 18.003.024 bytes. Portanto o próximo loader não pode depender de ler o
arquivo inteiro numa alocação contígua, e o filesystem precisa aceitar os nomes
Linux reais além do FAT 8.3 atual.

`build-radv.ps1` agora gera e audita também o runtime stripado em
`zig-out/mesa-sysroot/usr/lib/libvulkan_radeon.so` (18.003.024 bytes), mantendo
o ELF completo separado para diagnóstico. O teto defensivo por objeto do loader
subiu para 32 MiB e o pacote cabe nele. Isso remove a rejeição artificial por
tamanho; a alocação contígua duplicada ainda deve ser substituída por leitura
segmentada, enquanto instalação e nomes foram cobertos no incremento seguinte.

O VFS agora expõe os cinco nomes Linux canônicos do runtime e os traduz para
aliases FAT 8.3 internos, sem mudar os SONAMEs. A imagem opcional aceita RADV,
libdrm_amdgpu, libdrm, zlib e musl libc, e um boot confirmou o magic ELF de
todos por `/usr/lib/...`. O probe dinâmico mínimo carregou o RADV real e as
quatro dependências no CSOS, aplicou relocations, configurou TLS e chamou
`vk_icdNegotiateLoaderICDInterfaceVersion`; cinco objetos novos e recuperação
integral das páginas são gates do marcador `RADV dynamic loader ready`.
Isso comprova carregamento da stack real, mas ainda não executa a criação de
instância/dispositivo Vulkan, construtores gerais nem hardware Radeon.

O loader agora coleta `DT_INIT` e `DT_INIT_ARRAY` somente depois de aplicar
todas as relocations, ordena dependências antes dos consumidores e entrega a
lista ao intérprete Ring 3 por auxv privado. Testes de host continuam passando.
A primeira execução dos construtores revelou que a `libc.so` anteriormente
materializada pelo Zig é apenas uma DSO de símbolos/stubs: suas funções apontam
para uma `.text` de tamanho zero fora de `PT_LOAD`. O `DT_INIT` sentinela foi
tratado sem enfraquecer a validação dos construtores reais, mas
`__cpu_indicator_init` do RADV confirmou o mesmo defeito ao chamar libc. Dois
boots QEMU limitados reproduziram o fault em `libc.so + 0x15360` e foram
encerrados automaticamente. A `libc.a` completa do cache também não serve para
uma DSO porque foi compilada sem PIC. O próximo artefato obrigatório é uma musl
compartilhada real, compilada com PIC a partir das fontes e auditada antes de
repetir os construtores; o marcador antigo do probe não deve ser considerado
válido com construtores habilitados.

1. Construir e auditar uma musl compartilhada real com PIC, concluir a execução de `DT_INIT`/`DT_INIT_ARRAY`, e então inventariar e implementar no loader/ABI do CSOS os requisitos observados pelo `libvulkan_radeon.so` até executar libdrm_amdgpu/RADV real e validar command submission no caminho AMD GFX11 em hardware real.
2. Validar o primeiro triângulo AMD/RADV em Radeon real suportada.
3. Tornar NVIDIA a frente ativa de M14: adaptar a infraestrutura compartilhada e validar Nouveau/NVK ou stack compatível em uma máquina somente com GeForce suportada, incluindo inicialização, display, memória, filas, sincronização e triângulo Vulkan.
4. Integrar a seleção AMD/NVIDIA ao instalador e ao `hardware.csc`, incluindo o caso híbrido suportado.
5. Completar SDL, autoconfiguração, estabilidade, lifecycle e interface do SO.
6. Somente então trabalhar em Steam Runtime, Steam e CS2.

## Definition of Done

O projeto só está completo quando uma instalação reproduzível em máquina suportada comprovar:

```text
UEFI boot + SMP + memória + userspace
Linux ELF e ABI necessária
NVMe + filesystem
USB mouse/teclado + rede + áudio + display
AMD/RADV Vulkan em hardware real
NVIDIA/NVK ou stack compatível Vulkan em hardware real
seleção automática e independente do backend AMD/NVIDIA suportado
hardware discovery + hardware.csc + autotune
GAME/MATCH + freeze/standby/reclaim/resume
interface do sistema funcional
Steam Runtime + Steam + login/download
CS2 offline + online + partida completa
integração estável e performance medida
```

Até todos esses critérios passarem, o GOAL permanece ativo.
