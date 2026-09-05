# Auditoria de bring-up RADV

## Atualização de runtime em 2026-09-05

O bootstrap privado musl foi integrado ao loader por auxv, com descritores
TLS preservando os índices usados nas relocations DTPMOD64. A inicialização
precede todos os construtores. O probe passou em
`zig-out/smoke-cca7d71cbfc446b2a9d8c59ec7751334.serial.log`, incluindo
cookie de construtor com argumentos, negociação ICD, criação/destruição de
instância Vulkan e recuperação de páginas. O QEMU foi encerrado pelo runner.
Essa prova é de instância headless; não valida GPU física nem command submission.

musl v1.2.5 (`0784374d561435f7c787a555aeab8ede699ed298`) foi recompilada
integralmente: 1.347 objetos upstream, sem edição de tabelas de símbolos.
`link-musl-shared.py` fornece as três rotinas complexas PIC do compiler-rt
fixado e evita `-lgcc_eh`, que introduzia libunwind e stubs no link Zig.
A auditoria exige funções públicas em segmentos executáveis e verifica
SONAME, dependências e relocations. O ELF de 3.509.112 bytes passou e foi
instalado no staging; SHA-256
`8c275c3e6dfd669b1574c4dd413be3fa20c7ac2fee9350734cf084e00a282604`.
O checkout musl está limpo. O probe de criação Vulkan permanece pendente:
o carregador deve inicializar auxv e TLS musl antes dos construtores.
O sucesso de negociação anterior não comprova criação de instância Vulkan.

## Fontes verificadas

- Mesa `9311c93dbef6b87a30bc282c3683efefc5f26f77`.
- libdrm `773536b1e5dde694dd743815528aff8bb2cf2cc3`.
- CSOS após `c2a5471`.

Esta auditoria é de código, não execução de Mesa no CSOS nem prova de GPU real.

## Alinhamento do ring GFX11

Em `src/amd/vulkan/radv_queue.c`, `radv_update_preamble_cs` aloca os
`ge_rings_bo` de GFX11 com alinhamento de **2 MiB**, domínio VRAM e flags
`32BIT | DISCARDABLE`. O tamanho vem de
`total_attribute_pos_prim_ring_size`. O winsys, em `radv_amdgpu_bo.c`, transfere
o alinhamento para `request.phys_alignment`; o libdrm, em `amdgpu_bo.c`, o copia
para `drm_amdgpu_gem_create.in.alignment`.

Antes da correção, `kernel/syscalls.zig:amdgpuGemCreate` rejeitava alinhamento maior que
4096 antes de consultar o allocator VRAM. Portanto essa alocação retorna
`EINVAL` mesmo com firmware, GART e CP operacionais. Isso bloqueia a preparação
da fila gráfica; não é apenas uma otimização opcional.

O allocator `AmdVramAllocator.allocatePinned` já aceita potências de dois
maiores que uma página e alinha o endereço MC. O allocator físico usado no
caminho GTT agora oferece `allocateAligned`: preserva prefixo e sufixo livres,
mantém a lista ordenada e rejeita overflow antes de mutar o estado. GEM usa o
alinhamento normalizado (no mínimo uma página) tanto na VRAM quanto no GTT,
incluindo fallback VRAM/GTT, e o preserva no BO para GEM_OP.

Testes de host verificam o allocator físico com alinhamento de 2 MiB, split e
merge dos fragmentos, accounting, falta de espaço e overflow. O handler GEM
real é testado com VRAM sintética: endereço MC de 2 MiB, GEM_OP, falta de um
segundo slot alinhado, liberação e normalização de 64 bytes para uma página.
O teste de host Windows também reserva memória baixa para executar o handler
GEM GTT sem relaxar o limite físico de 44 bits. Ele verifica GTT direto e
fallback após esgotamento do allocator VRAM real: endereço de 2 MiB, GEM_OP,
limpeza somente do BO, padding intacto, falta de espaço e devolução integral
na liberação. Esse teste é explicitamente ignorado em hosts não Windows;
os demais testes de alinhamento continuam portáveis.
Ainda falta executar GEM GTT/fallback em Ring 3 e a alocação do ring pelo
RADV real; os testes de host não substituem isso.

### Critérios de verificação

1. Acrescentar alocação física alinhada com preservação dos fragmentos livres,
   accounting e liberação corretos; não desperdiçar silenciosamente o padding.
2. Normalizar alinhamentos menores que uma página para 4096 e aceitar potências
   de dois maiores, com checagem de overflow antes de qualquer mutação.
3. Passar o alinhamento normalizado aos allocators VRAM e GTT e preservá-lo no BO.
4. Testar a requisição GFX11 de 2 MiB no handler GEM real, verificando endereço
   MC alinhado, GEM_OP, falha por falta de espaço e liberação da reserva.
5. Testar também GTT e fallback VRAM/GTT para não anunciar alinhamento falso.

## Regressão Ring 3 corrigida

As iterações por valor sobre os 4096 mapeamentos GPUVA excediam a stack de
syscalls de 64 KiB e corrompiam `drm_pages`; o fechamento do BO GTT então não
devolvia sua página. Iterações por referência em `drivers/gpu.zig` e
`kernel/syscalls.zig` reduziram o pico medido de 170.504 para 11.920 bytes.
Não houve compensação do contador, restauração artificial do ponteiro nem
ampliação permanente da stack. A instrumentação temporária foi removida.

Validação final sem instrumentação: `zig build test --summary all` passou
10/10 testes. Os dois boots limitados exigiram `CSOS M17 process reclaim ready`:

- AMDGPU Ring 3: `zig-out/smoke-5adec999b48a4b0aaf71f9031c79b290.serial.log`.
- Boot normal: `zig-out/smoke-a47833e92f8a4574bcc86190e4072f8c.serial.log`.

Ambos passaram e encerraram QEMU. Isso valida a recuperação do teste, não
execução RADV nem aceleração em hardware real.

### Histórico do diagnóstico (superado pela correção acima)

`zig build run -Ddrm-amdgpu-abi-test=true -- -SmokeTestSeconds 15 -ExpectSerial "CSOS M17 process reclaim ready"`
seleciona a ABI AMDGPU somente durante `drmtest`, antes da inicialização da GPU,
e restaura o driver detectado em seguida. Não altera PCI nem ativa aceleração.
O programa passou GEM GTT com alinhamento de 2 MiB e GEM_OP, além dos ioctls AMD
já existentes. Foi necessário corrigir o teste de versão para aceitar major 3
do AMDGPU, além de major 1 dos outros backends.

Contudo, a verificação posterior de recuperação falhou: 50099 páginas livres
antes, 50098 depois. A execução NÃO está aprovada integralmente. A causa dessa
página pendente ainda precisa ser isolada; os diagnósticos adicionados não
reportaram falha de dematerialização da VM DRM. O teste é opt-in e o padrão
não altera o driver. Próxima ação: corrigir a recuperação sem relaxar a
igualdade de contagem e repetir exigindo o marcador M17, não só o marcador DRM.

### Revalidação da regressão

A imagem sem instrumentação voltou a falhar com 50099 → 50098 páginas.
Uma imagem com duas mensagens temporárias em `resetDrmVm` mostrou incremento
de 47749 para 47750 páginas na dematerialização e passou pelo marcador M17.
Removidas as mensagens, a falha de uma página retornou. As mensagens temporárias
não foram mantidas: alterar o layout/tempo da imagem não constitui correção.
Essa comparação enfraquece a hipótese de simplesmente faltar liberar a raiz
DRM, mas não identifica a causa. A próxima investigação deve rastrear as
alocações/liberações por endereço e fase, incluindo fragmentação e page tables
CPU; não compensar a contagem nem descartar a página como custo esperado.
Logs locais preservados em `zig-out`: `smoke-7e553ec48c9b4d5c9c7abe72b9abedb0.serial.log`
(instrumentado, passou) e `smoke-71668f1bc9294576bc1f07c37b19e1ec.serial.log`
(sem instrumentação, falhou). Ambos os QEMUs foram encerrados pelo runner.

## Cobertura adicional de fallback em Ring 3

O `drmtest` executa agora duas passagens AMDGPU: domínio GTT (`2`) e domínio
VRAM|GTT (`6`), antes de instalar o backend VRAM. Ambas verificam GEM_OP com
domínio efetivo GTT e alinhamento de 2 MiB, metadata, enumeração de handles,
map/unmap GPUVA, rejeição de close enquanto mapeado, wait-idle e liberação.
O gate agora exige 55 ioctls bem-sucedidos, quatro mmaps DRM e cinco objetos
alocados/liberados.
O teste passou até M17 no log `zig-out/smoke-f0ab6d08bd29428381e91d93f300cc4a.serial.log`.
Isso cobre backend VRAM ausente; esgotamento de VRAM continua coberto apenas
no host, e execução RADV real continua pendente.

## Gate de aceleração

O ciclo AMDGPU Ring 3 agora abre o render node para criar e mapear os BOs,
como `amdgpu_bo_cpu_map` upstream. Antes da correção, GEM_MMAP retornava offset,
mas mmap rejeitava render nodes porque reconhecia apenas o nó primário.
O kernel agora aplica o mesmo caminho DRM aos dois tipos de nó, preservando
validação de BO, limites, MAP_SHARED, proibição de execução e NO_CPU_ACCESS.
O teste verifica leitura inicial de zero, escrita/leitura e munmap em cada BO.
Antes do mmap válido, cada passagem exige EINVAL para PROT_READ|PROT_EXEC,
MAP_PRIVATE e offset na primeira página além do BO. Os casos negativos não
alteram a contagem esperada de quatro mmaps DRM. A validação com esses casos
passou até o console em `zig-out/smoke-d9e0e62001f245189ddc10e6546921df.serial.log`.
Controle negativo: `smoke-3ae6fea24be24c53b75d2cc7d72a29a6.serial.log` falhou;
após a correção `smoke-a54cb76074d44536bb9f1fab0ccbbe83.serial.log` passou até M17
(ambos em `zig-out`). Isso não valida isolamento de handles entre diferentes
aberturas DRM nem execução RADV real.

`amdgpu_device_initialize` aborta se `AMDGPU_INFO_ACCEL_WORKING` for zero.
O CSOS agora consulta a saúde do backend físico após o teste PM4, em vez de
exigir Vulkan validado antes de permitir a inicialização do próprio RADV.
Essa correção possui testes de host; ativação física e execução libdrm/RADV
continuam pendentes.

## Limite da conclusão

### Próxima validação com libdrm original

`tools/build-libdrm-probe.ps1` compila `userspace/libdrm_probe.c` junto dos
fontes originais do libdrm, com Zig e musl, como ELF Linux x86-64 estático.
O script exige checkout limpo na revisão `773536b1e5dde694dd743815528aff8bb2cf2cc3`
em `.tools/libdrm-src` (ou `-SourceDirectory`) e Python para o gerador upstream
da tabela fourcc. O perfil de compilação fica em `tests/libdrm_config.h`.

Build validado: `powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-libdrm-probe.ps1`.
Saída: `zig-out/libdrm-probe/libdrm-probe`. O programa usa `drmGetVersion` e
`drmGetDevice2` reais. A integração opt-in usa
`zig build run -Dlibdrm-probe=zig-out/libdrm-probe/libdrm-probe -- -SmokeTestSeconds 12 -ExpectSerial "CSOS M17 process reclaim ready"`.

A execução real revelou três incompatibilidades corrigidas: comando ioctl
estendido com sinal por musl (normalizado para `u32`), sugestões de endereço
`mmap` tratadas como obrigatórias sem MAP_FIXED e stack de userspace insuficiente
para os buffers PATH_MAX aninhados do libdrm/libc. A stack de userspace agora
tem 128 KiB e RSP inicial no topo; a stack de syscalls continua com 64 KiB.

Sem os diagnósticos temporários, o teste combinado com AMDGPU Ring 3 passou:
`zig-out/smoke-26778d9e49314e9d91a1708823cd6ed0.serial.log`. O libdrm original
imprime `csosdrm 1.0`, PCI `1234:1111` e `CSOS real libdrm discovery ready`;
a checagem posterior de recuperação de páginas também passa. `zig build test`
passou 10/10 testes. Essa prova é de descoberta da GPU QEMU pela ABI real,
não de inicialização libdrm_amdgpu, RADV ou Vulkan em Radeon/NVIDIA.

Resolver o alinhamento não comprova que todas as dependências do RADV estejam
implementadas.

### Variante com libdrm_amdgpu original

O probe genérico também verifica a duplicação via `F_DUPFD_CLOEXEC` usada pelo
libdrm_amdgpu: o novo fd deve ser distinto, manter a classificação render e
aceitar `drmGetVersion`; fechá-lo não pode invalidar o original. Essa verificação
não testa fechamento em exec nem compartilhamento de offsets de arquivos.

Os flags de descritor agora são armazenados: O_CLOEXEC e F_DUPFD_CLOEXEC definem
FD_CLOEXEC, F_GETFD/F_SETFD consultam/alteram o bit independentemente por fd,
e dup2/F_DUPFD limpam o bit na cópia (dup2 de um fd para ele mesmo preserva).
O probe real verifica os flags e a independência entre original/cópia; o
self-test de host cobre também dup2 e EBADF após close. Ambos passaram,
incluindo boot até o console no log
`zig-out/smoke-857bc09500ab42299f90f0b8b47e96e2.serial.log` e 10/10 testes de host.
Ainda falta validar/aplicar fechamento automático na futura transição execve;
F_GETFL/F_SETFL continuam fora desta implementação de flags de descritor.

O teste expôs stdin não registrado no VFS: `duplicateMinimum(..., 0)` alocava
fd 0, mas `fstat` o tratava como console. `reset()` agora registra os três
descritores padrão. Após a correção, duplicação, descoberta, recuperação de
páginas e console passaram em `zig-out/smoke-e4fef2bf2c2349de889381ea2f396d55.serial.log`;
os 10 testes de host também passaram.

Regressão de host adicionada ao self-test de identidade PCI: exige os três
descritores padrão abertos, fd duplicado distinto e fora de 0–2, identidade
render/rdev preservada, original válido após fechar a cópia e reutilização do
slot liberado. Controle negativo: remover temporariamente o registro do stdin
produziu `StandardDescriptorMissing` (9/10 testes); restaurar a correção voltou
a 10/10. O controle negativo não foi mantido no código.

Inventário somente-leitura do host Windows: AMD `1002:164e` e NVIDIA GeForce
RTX 4060 Ti `10de:2803`. Presença no host não demonstra suporte CSOS, revisão
de IP compatível, passthrough disponível ou validação bare-metal. Nenhum reboot,
desligamento de driver do host ou passthrough foi realizado.

`tools/build-libdrm-probe.ps1 -AmdGpu` compila também os nove fontes AMDGPU
upstream e gera `zig-out/libdrm-probe/libdrm-amdgpu-probe`. Essa variante chama
`amdgpu_device_initialize` e `amdgpu_device_deinitialize` reais, sem substituir
capabilities por dados sintéticos. O build estático foi validado.

No QEMU, a primeira execução não chegou à validação da GPU: falhou antes, em
`amdgpu_get_auth`, com ioctl `0xc0286405` não atendido e syscall 21 (`access`)
ausente. O próximo passo é rastrear a classificação do render node e o caminho
de autenticação; não interpretar essa falha de ABI como validação do gate
de hardware. Log: `zig-out/smoke-e15e3ede827f4f04821c6c3f4a5f6a95.serial.log`.
O runner encerrou QEMU; inicialização AMDGPU real continua pendente.

A classificação foi corrigida implementando `access(path, F_OK)` pela resolução
real do VFS. Bits de modo inválidos retornam EINVAL; consultas de permissões
R/W/X ainda retornam EOPNOTSUPP, sem anunciar uma política de credenciais que
não existe. `drmGetNodeTypeFromFd` agora reconhece o render node, e a variante
AMDGPU avança até a rejeição correta de DRM 1.0 por exigir 3.x, em vez de cair
em autenticação legada. Log: `zig-out/smoke-811dbb9eabef4ec7890108603ea9839c.serial.log`.
O probe genérico passou a exigir explicitamente `DRM_NODE_RENDER`.

### Ponto de execução após a inicialização gráfica

`-Dlibdrm-probe-after-gpu=true` move o ELF fornecido por `-Dlibdrm-probe`
para depois da preparação gráfica, sem habilitar nenhum gate MMIO. Exige um
ELF explícito e verifica a recuperação de páginas após a execução. O marcador
correto desse modo é `CSOS post-GPU libdrm reclaim ready`, não o M17 anterior.

O primeiro teste expôs um unwrap incondicional de `gpu_ip_discovery` na consulta
de caches, mesmo em GPU não AMD. A consulta agora exige discovery presente,
sem inventar topologia para QEMU/NVIDIA. Retirados os marcadores temporários,
o modo pós-GPU passou pela descoberta libdrm, recuperação de páginas e console:
`zig-out/smoke-ae274d4fbd8d4da7922bbc8238c8b37e.serial.log`.
O runner exigiu `CSOS console shell ready`; `zig build test` passou 10/10.
Isso comprova o caminho QEMU até o console, não aceleração física AMD/NVIDIA.

Resolver essas dependências ainda não comprova que todas as funções RADV estejam
implementadas. Ainda é necessário construir e executar a stack real, observar
as próximas falhas e validar um triângulo em Radeon suportada. NVIDIA continua
obrigatória depois desse primeiro caminho AMD; Steam/CS2 permanecem no final.

### Regressão de overflow de comprimento nas syscalls de memória

`mmap`, `mprotect` e `munmap` rejeitam comprimento acima de `UINT64_MAX - 4095`
antes do arredondamento para páginas. Isso evita panic por overflow provocado
por userspace. O teste AMDGPU Ring 3 usa `UINT64_MAX`, exige `ENOMEM` nos dois
primeiros casos e `EINVAL` em `munmap`, e verifica que o BO continua legível e
gravável após as chamadas rejeitadas, antes do unmap válido.

`tools/test-system.ps1 -SmokeTestSeconds 20` terminou com código zero: 10/10
testes de host e ambos os boots até `CSOS console shell ready`. Evidências:

- Normal: `zig-out/smoke-d9f153f4d2a743e7b3272ff74f3ea397.serial.log`.
- AMDGPU ABI e libdrm pós-GPU: `zig-out/smoke-56f9697d9fa04dc098012158209a3935.serial.log`.

Nenhum processo QEMU permaneceu aberto. A validação não comprova Vulkan físico.

### Probe de ciclo GTT pela biblioteca AMDGPU original

A variante `-AmdGpu` agora chama, após inicialização real do dispositivo,
`amdgpu_bo_alloc` para 4 KiB GTT com alinhamento físico solicitado de 2 MiB,
`amdgpu_bo_cpu_map`, escrita/leitura de toda a página, `amdgpu_va_range_alloc`
com alinhamento virtual de 2 MiB, `amdgpu_bo_va_op` MAP/UNMAP e as liberações
correspondentes. Erros preservam a primeira falha e tentam liberar os recursos
adquiridos. O teste CPU não comprova acesso pela GPU, alinhamento físico efetivo,
command submission ou triângulo Vulkan.

Build estático AMDGPU aprovado. O teste negativo pós-GPU em QEMU manteve a
rejeição DRM 1.0 versus 3.x e não chegou ao novo ciclo GTT:
`zig-out/smoke-0aebfc8ea3334be8a7f8792f37a1bb1f.serial.log`. O runner exigiu
explicitamente `post-GPU libdrm probe failed`; o código zero do runner neste
caso significa rejeição observada, não sucesso AMDGPU. O log também mostra
syscall 204 não implementada, sem impedir a descoberta PCI.

A suíte normal continuou passando 10/10 testes de host e dois boots até o
console: `zig-out/smoke-21aa20829a9440edbd26d709d79bfb88.serial.log` e
`zig-out/smoke-cbe3fd903e954318be2cdc0eb83147d4.serial.log`.

### Triagem da syscall 204 e do carregamento da stack real

A syscall 204 ausente é `sched_getaffinity`. Na musl local, `src/conf/sysconf.c`
inicializa a máscara com `{1}`, chama essa syscall e conta os bits mesmo se a
chamada falhar. Portanto esse caminho de consulta retorna uma CPU por fallback;
a ausência não explica a rejeição da versão DRM no probe. Isso não implementa
afinidade nem prova que software multithread funcionará. O scheduler registra
CPUs por APIC ID e mantém filas de workers separadas; não se deve anunciar uma
máscara de CPUs para userspace sem vinculá-la à política real de execução.

O loader em `kernel/process.zig` aceita apenas o intérprete `/lib/ld-csos.so`
e limita a quatro objetos compartilhados (`max_shared_objects`). Logo os
probes estáticos musl não comprovam carregamento de um runtime Linux dinâmico
real. O diretório `C:/git/csos-mesa-audit` contém apenas partes de `src/amd` e
`src/util`, não um checkout completo pronto para construir Mesa.

Antes de declarar RADV executável, será necessário obter um build reproduzível
da stack escolhida, inspecionar seus ELF/PT_INTERP/DT_NEEDED e relocations e
atender às dependências observadas. Não basta aceitar outro nome de intérprete
ou aumentar o limite de bibliotecas. A validação física AMD continua necessária
em paralelo a essa preparação; NVIDIA permanece obrigatória após o caminho AMD.

### Checkout Mesa completo e ferramentas de configuração

Foi obtido um checkout separado em `.tools/mesa-src`, do upstream
`https://gitlab.freedesktop.org/mesa/mesa.git`, detached na revisão auditada
`9311c93dbef6b87a30bc282c3683efefc5f26f77` (`26.3.0-devel`). A árvore completa
foi materializada e `git status --porcelain --untracked-files=no` ficou vazio.
O checkout parcial anterior não foi expandido nem teve fontes alterados.

Meson/Ninja/Mako e dependências Python foram instalados no venv isolado
`.tools/mesa-build-env`. Versões estão fixadas em
`tools/mesa-build-requirements.txt`; preparação reproduzível a partir da raiz:

```powershell
python -m venv .tools/mesa-build-env
.tools/mesa-build-env/Scripts/python.exe -m pip install -r tools/mesa-build-requirements.txt
```

Isso prepara ferramentas, não um build Mesa aprovado. O Meson upstream exige
ao menos versão 1.4.0 e usa C11/C++17. Próxima etapa: configurar cross-compilation
Linux x86-64 com o Zig fixado e resolver as dependências target observadas,
mantendo os geradores nativos separados das bibliotecas Linux. O Ubuntu WSL
existe, mas a consulta não encontrou meson, ninja, gcc, pkg-config ou llvm-config;
nenhum pacote global ou driver do host foi alterado. QEMU não foi iniciado.

### Primeira configuração cross do RADV

`tools/mesa-linux-cross.ini` define Zig C/C++ para `x86_64-linux-musl`, sem
execução automática dos binários target. `tools/mesa-windows-native.ini`
define os compiladores Windows dos geradores. `tools/configure-radv.ps1`
valida a revisão e a árvore Mesa, prepara PATH apenas durante a execução e
expõe o perfil inicial RADV/ACO sem Gallium, OpenGL, WSI, LLVM ou shader cache.
Esse perfil serve ao bring-up; não é a configuração final de display do SO.

A primeira execução de Meson setup reconheceu os quatro compiladores C/C++,
passou os sanity checks e confirmou ponteiros Linux de 8 bytes. Terminou com
erro em `meson.build:747`: `glslangValidator` não encontrado. Log completo em
`zig-out/mesa-radv/meson-logs/meson-log.txt`. O próximo requisito é disponibilizar
o compilador de shaders nativo genuíno, sem substituir sua saída por um stub.
O libdrm já fixado é 2.4.134, suficiente para o mínimo 2.4.133 desse RADV,
mas suas bibliotecas target e metadados de descoberta ainda não foram preparados.
Nenhum artefato RADV ou Vulkan funcional foi produzido nesta configuração.

### glslang resolvido; descoberta de libdrm é a próxima dependência

O release oficial Khronos glslang 16.5.0 Windows x86-64 foi instalado em
`.tools/glslang-16.5.0`. `tools/prepare-glslang.ps1` fixa a URL do release,
confere o SHA-256 do ZIP publicado no GitHub e o hash do executável extraído,
preserva instalações existentes em caso de divergência e testa `--version`.
O hash do ZIP é `06b71298b750268c127f2ee7ae0ef7525e2068120c6c8a3a08b2f58ca6f325ce`.
Fonte: https://github.com/KhronosGroup/glslang/releases/tag/16.5.0.

O pacote fornece `glslang.exe`; o native file o vincula explicitamente à chave
`glslangValidator` esperada por Mesa, sem renomear nem substituir o programa.
`prepare-glslang.ps1` passou e `configure-radv.ps1` avançou até encontrar essa
ferramenta. A configuração terminou com erro em `meson.build:813`: pkg-config
para o target não está disponível e libdrm não foi encontrado. Próximo passo:
preparar a ferramenta de descoberta nativa com caminhos restritos às bibliotecas
Linux e construir/instalar libdrm no prefixo target. Não usar bibliotecas Windows
como substitutas nem suprimir a dependência AMDGPU para produzir um build verde.
Log atual: `zig-out/mesa-radv/meson-logs/meson-log.txt`. QEMU não foi iniciado.

### Bibliotecas libdrm Linux compiladas e staging validado

`tools/build-libdrm-linux.ps1` configurou libdrm 2.4.134 original, compilou seus
18 passos e instalou headers, bibliotecas e metadados no staging
`zig-out/mesa-sysroot/usr`. A configuração limpa foi repetida depois de detectar
um defeito no launcher Python de pkgconf 2.5.1.post2: quando PKG_CONFIG_LIBDIR
está definido, `_vanilla_entrypoint` termina sem executar a consulta e retorna
sucesso vazio. O cross file agora usa diretamente o executável genuíno
`pkgconf/.bin/pkgconf.exe`. `atomic_ops` passou corretamente de falso positivo
para não encontrado; os atomics nativos do compilador passaram e o build foi
revalidado. A árvore upstream não foi modificada.

pkgconf nativo retorna 2.4.134 para libdrm e libdrm_amdgpu e flags restritos ao
staging. `readelf` confirma ELF64 little-endian x86-64 DYN; SONAMEs
`libdrm.so.2` e `libdrm_amdgpu.so.1`. O primeiro exige `libc.so`; o segundo,
`libc.so` e `libdrm.so.2`. Nenhum RPATH/RUNPATH aparece nos dois instalados.
Isso é inventário real de artefatos, não validação de execução no CSOS.

Sem privilégios de symlink Windows, o script fornece cópias byte-idênticas para
os aliases do linker e SONAME. Na reinstalação ele remove apenas aliases
gerados cujo hash ainda coincide com o original, preserva divergências e
recria os aliases após o install. A reinstalação passou. As bibliotecas originais
permanecem disponíveis; nenhum arquivo do usuário foi removido.
pkgconf e colorama foram fixados no requirements isolado. QEMU não foi iniciado.

### Descoberta RADV confirmada e testes de símbolos upstream

`meson test -C zig-out/libdrm-linux --no-rebuild --print-errorlogs` passou os
dois testes upstream, `core-symbols-check` e `amdgpu-symbols-check`. O script
`build-libdrm-linux.ps1` agora exige esses testes antes de instalar. Evidência:
`zig-out/libdrm-linux/meson-logs/testlog.txt`. São verificações nativas dos
símbolos ELF; não executam as bibliotecas no CSOS.

A configuração RADV repetida registrou `Run-time dependency libdrm found: YES
2.4.134` e o mesmo para `libdrm_amdgpu`, com o pkgconf nativo e staging isolado.
Ela avançou às verificações de builtins do compilador. Esse marco remove a
falha anterior de descoberta, mas não declara configuração completa nem build
RADV concluído. Acompanhar o processo existente até seu resultado, sem iniciar
outra configuração concorrente sobre `zig-out/mesa-radv`.

Validação adicional durante as sondagens: o glslang oficial compilou o shader
upstream `src/amd/vulkan/bvh/copy_addrs.comp`, usando os três include dirs do
Meson e as extensões `vk_glsl_shader_extensions` do runtime BVH, com `-V -x
--target-env spirv1.5`. Saída: `zig-out/radv-shader-audit/copy_addrs.spv.h`,
35.180 bytes, começando com magic SPIR-V `0x07230203` e versão `0x00010500`.
Isso comprova geração desse shader original, não validação semântica por
spirv-val, compilação de todo RADV nem execução na GPU. A configuração principal
continuou ativa e avançando; nenhum segundo setup foi iniciado.

### zlib Linux preparada para o RADV

A configuração RADV terminou depois das sondagens de compilador/headers em
`meson.build:1871`, com zlib obrigatória e ausente. O requisito não foi
desativado. Foi fixado o upstream zlib 1.3.1 na revisão
`51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf`; seu checkout em `.tools/zlib-src`
permanece limpo. CMake 3.31.6 foi adicionado ao venv/requirements isolado.

`tools/zig-linux-toolchain.cmake` usa Zig para Linux x86-64 musl e restringe
bibliotecas/includes/packages ao staging. `tools/build-zlib-linux.ps1` valida
revisão e árvore, configura/compila/instala e verifica a assinatura ELF. Como o
CMake oficial da zlib renomeia o `zconf.h` da source tree, o script trabalha em
`zig-out/zlib-source`, nunca no checkout fixado. A compilação passou 33 passos.

pkgconf retorna zlib 1.3.1. `readelf` confirma ELF64 x86-64, SONAME
`libz.so.1`, única NEEDED `libc.so` e nenhum RPATH/RUNPATH. A repetição do setup
RADV foi iniciada com o processo existente e deve ser acompanhada até o próximo
resultado antes de reiniciar. `configure-radv.ps1` agora exige previamente os
três metadados target: libdrm, libdrm_amdgpu e zlib. QEMU não foi iniciado.

### Configuração completa e primeira compilação RADV

Com zlib no staging, o setup terminou com código zero: 99 targets, Vulkan AMD,
libdrm/libdrm_amdgpu 2.4.134, zlib 1.3.1, ACO sem LLVM e sem Gallium/OpenGL/WSI.
Esse é deliberadamente um perfil headless de bring-up, não o produto final.

`tools/build-radv.ps1` preserva a revisão/árvore Mesa, injeta o PATH isolado e
executa Ninja com paralelismo configurável. A primeira compilação produziu os
geradores, shaders BVH, NIR, runtime Vulkan, AMD common, addrlib e ACO; chegou a
770/770 e falhou somente no link de `libvulkan_radeon.so`. O frontend Zig recebeu
`-Wl,--version-script` e `vulkan.sym` separadamente e tratou o segundo como fonte
de extensão desconhecida. Não foi removido o version script para obter sucesso.

`tools/zig-cc-wrapper.py` conserva os argumentos e, apenas dentro de response
files, combina o par na forma GNU aceita por Zig:
`-Wl,--version-script=<arquivo>`. O cross file passou a usar esse wrapper nos
compiladores target. Como Meson mantém o compilador no coredata, reconfigure não
foi suficiente; `configure-radv.ps1 -Wipe` recria somente o build gerado.

### RADV ligado e ELF auditado

O segundo link revelou `__cpu_model` indefinido no addrlib: o Clang baixa
`__builtin_cpu_supports("avx2")` para o runtime x86 do compiler-rt, que Zig
0.16.0 não inclui nesse shared object. SIMD não foi desativado e nenhum símbolo
falso foi criado. O checkout esparso oficial llvm-project 21.1.0 foi fixado na
revisão `3623fe661ae35c6c80ac221f14d85be76aa870f1`; o script
`tools/build-compiler-rt-cpu-model.ps1` compila seu
`compiler-rt/lib/builtins/cpu_model/x86.c` como ELF PIC e o cross file o liga.
Os símbolos `__cpu_indicator_init` e `__cpu_model` ficaram locais e hidden.

O Meson hospedado no Windows também tentou inserir o caminho absoluto do
staging como RUNPATH Linux. O wrapper remove especificamente argumentos RPATH
com drive Windows nos response files, sem alterar bibliotecas ou SONAME. Uma
configuração limpa confirmou includes do staging corretos e o build concluiu
770/770. `readelf` verificou ELF64 little-endian x86-64 DYN, SONAME
`libvulkan_radeon.so`, nenhum RPATH/RUNPATH e NEEDED somente
`libdrm_amdgpu.so.1`, `libz.so.1`, `libdrm.so.2` e `libc.so`. `nm -D` mostra
somente `vk_icdGetInstanceProcAddr`, `vk_icdGetPhysicalDeviceProcAddr` e
`vk_icdNegotiateLoaderICDInterfaceVersion` como exports definidos.

Esse marco comprova a compilação real do RADV, não o carregamento dinâmico no
CSOS, a suficiência da ABI, command submission físico nem triângulo Vulkan. A
próxima etapa é inventariar os requisitos ELF/syscalls desse artefato e executar
o caminho real em Radeon suportada. NVIDIA/NVK permanece obrigatória depois do
triângulo AMD e antes de SDL/Steam. QEMU não foi iniciado.

### Primeiro inventário contra o loader do CSOS

Os quatro segmentos LOAD do RADV somam 4.423 páginas considerando os limites
alinhados de cada segmento. O loader atual usa `max_mappings = 512` e
`max_owned_ranges = 512`, ambos como arrays locais de `runImage`; portanto o
driver não pode ser carregado e aumentar esses arrays na stack apenas trocaria
o erro de capacidade por overflow. As dependências transitivas ainda precisam
entrar no dimensionamento.

A tabela de relocations contém 12.715 `R_X86_64_RELATIVE`, 270
`R_X86_64_JUMP_SLOT`, três `R_X86_64_GLOB_DAT` e um `R_X86_64_DTPMOD64`. Esses
quatro tipos já existem no loader. O ELF também possui TLS de 24 bytes e duas
entradas em `DT_INIT_ARRAY`; relocação suportada não basta, pois o loader ainda
precisa executar construtores e obter `libdrm_amdgpu.so.1`, `libz.so.1`,
`libdrm.so.2` e `libc.so` do filesystem em vez de depender apenas dos objetos
de teste embutidos. Esse é o próximo recorte antes de execução física.

O primeiro recorte foi implementado em `kernel/process.zig`: mappings e ranges
de propriedade passaram de arrays locais de 512 entradas para um workspace BSS
serializado de 8.192 entradas. A capacidade cobre as 4.423 páginas auditadas e
mantém folga para dependências, sem consumir a stack do kernel. O desenho é
explicitamente provisório até processos/exec concorrentes exigirem estado por
processo. `zig build test` passou e `tools/test-system.ps1` confirmou 10/10
testes de host mais os boots normal e AMDGPU/libdrm pós-GPU até
`CSOS console shell ready`; os dois QEMUs foram encerrados pelo runner. Ainda
faltam construtores, arquivos target na imagem e execução do ICD real.

`tools/audit-radv-elf.ps1` transforma o inventário em gate: exige arquitetura,
SONAME, quatro NEEDED exatos, ausência de RPATH/RUNPATH, três exports ICD,
runtime de CPU local/hidden, somente relocations já suportadas e páginas LOAD
dentro da capacidade lida diretamente de `kernel/process.zig`.
`tools/build-radv.ps1` executa essa auditoria após Ninja; o build incremental e
o gate passaram. Uma cópia experimental com debug removido mede 19.084.448
bytes (18.003.024 com strip completo), ainda acima do limite atual de 16 MiB
por shared object. Logo, retirar debug reduz o desperdício, mas não elimina a
necessidade de ampliar o carregamento por arquivo/segmento nem o suporte a nomes
e caminhos Linux além do FAT 8.3 atual.

O fluxo de build agora preserva o ELF completo para diagnóstico e produz com
`strip --strip-all` o runtime de 18.003.024 bytes em
`zig-out/mesa-sysroot/usr/lib/libvulkan_radeon.so`. Ambos passam a auditoria;
no arquivo stripado, a ausência dos nomes locais é aceita somente após garantir
que `__cpu_model` e `__cpu_indicator_init` não aparecem na tabela dinâmica. O
limite defensivo do loader passou a 32 MiB, suficiente para esse pacote. Ainda
é necessário eliminar a cópia contígua do arquivo; os nomes/caminhos Linux e a
inclusão opcional na imagem foram cobertos no incremento seguinte.

O VFS passou a traduzir nomes canônicos (`/usr/lib/libvulkan_radeon.so` e os
quatro SONAMEs dependentes) para aliases FAT 8.3 internos. A tradução possui
self-test e não é visível à ABI. `make-fat16.ps1` aceita os cinco ELF opcionais
em entradas contíguas; uma imagem foi inspecionada e registrou RADV com
18.003.024 bytes, libdrm_amdgpu com 186.832, libdrm com 368.584, zlib com
298.464 e musl libc com 141.096 bytes. `build-musl-runtime.ps1` materializa a
libc target pelo Zig e exige exports fundamentais antes do staging.

`userspace/radv_loader_probe.c` possui `DT_NEEDED libvulkan_radeon.so`, usa
`/lib/ld-csos.so` e chama `vk_icdNegotiateLoaderICDInterfaceVersion`. Em QEMU,
o CSOS abriu os cinco arquivos pelos caminhos canônicos, carregou RADV e as
quatro dependências, aplicou relocations, criou TLS e executou o entrypoint. O
gate exige cinco objetos adicionais, relocations efetivas, ao menos um módulo
TLS e igualdade de páginas livres depois do processo. O marcador
`RADV dynamic loader ready` passou e o QEMU foi encerrado. Construtores gerais,
`vkCreateInstance`, descoberta Radeon e command submission continuam pendentes.

## Construtores e runtime musl

O loader passou a coletar `DT_INIT` e `DT_INIT_ARRAY` após todas as relocations,
em ordem de dependências antes dos consumidores, e o intérprete Ring 3 passou a
executá-los antes do entrypoint. `zig build test` continuou passando.

A execução invalidou a libc usada no primeiro probe: o `libc.so` materializado
pelo Zig tem 141.096 bytes, mas é uma DSO de link com símbolos apontando para
`.text` de tamanho zero em `0x15360`, fora de qualquer `PT_LOAD` executável. O
próprio `DT_INIT` contém esse endereço sentinela; depois de ignorar somente essa
entrada não mapeada, `__cpu_indicator_init` do RADV chamou uma função libc e
reproduziu o fault em `0x6040015360` (`libc.so + 0x15360`). Os dois boots foram
limitados a 60 segundos e seus QEMUs foram encerrados. Tentar relinkar a
`libc.a` completa do cache como DSO também foi rejeitado por relocations sem
PIC. Assim, o resultado anterior prova carga/relocation/negociação do ICD, mas
não prova uma libc executável nem construtores. O próximo gate exige compilar
musl compartilhada real com PIC e repetir o probe.
