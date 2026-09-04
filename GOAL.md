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

## Ordem das milestones

- [x] **M0–M13 — fundações do SO:** build, boot, memória, CPU/SMP, scheduler, userspace, ABI Linux inicial, BusyBox, PCIe, NVMe, filesystem, USB/xHCI, rede e áudio possuem fundações implementadas; integração e validação final ainda continuam.
- [ ] **M14 — GPU AMD/NVIDIA + Vulkan:** parcial. A preparação AMD GFX11, `AMDGPU_INFO_DEV_INFO`, `AMDGPU_INFO_MEMORY`, a leitura restrita do `GB_ADDR_CONFIG` físico e as consultas obrigatórias de firmware ME/MEC/PFP possuem implementação e testes de host. As versões vêm dos blobs GFX11 selecionados e validados. O contrato GPUVA já faz o libdrm derivar `address32_hi = 0`, e DRM 3.54 só é anunciado quando os perfis físico/memória/firmware, allocator VRAM e command submission estão instalados; `ACCEL_WORKING` continua zero até validação Radeon real. GEM aceita placement real na VRAM visível, mantém endereços CPU/MC separados, instala PTEs GPUVA sem atributos de memória de sistema, atualiza uso/capacidade das heaps VRAM e GTT e aplica semântica explícita aos flags de criação usados pelo RADV. `AMDGPU_CS` aceita a BO list inline e até 192 IBs GFX do RADV atual, com validação individual, residência, BOs `VM_ALWAYS_VALID` e uma única conclusão física. Capacidade PCIe combinada, tipo/largura de VRAM via ATOM, clocks e snapshots físicos de CUs/RBs/TCC/UMCs ativos também estão cobertos. A identidade PCI Linux compartilhada agora publica major/minor dos nós DRM, `uevent`, IDs PCI reais e o vínculo de subsistema exigido por `drmGetDevice2`, com `readlink`/`readlinkat` e teste de host. VRAM não visível ainda não é alocável. Shadow/CSA/userq permanecem corretamente desabilitados; validação do libdrm no userspace real, execução Radeon real e triângulo RADV ainda faltam. Depois do triângulo AMD, NVIDIA/NVK ou stack compatível deve funcionar de forma independente em uma máquina somente NVIDIA e também exige validação real de inicialização, memória, filas, sincronização e triângulo Vulkan.
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

1. Executar o libdrm/RADV real sobre a identidade PCI Linux implementada, corrigir somente incompatibilidades observadas e validar command submission no caminho AMD GFX11 em hardware real.
2. Validar o primeiro triângulo AMD/RADV em Radeon real suportada.
3. Adaptar a infraestrutura compartilhada para NVIDIA e validar Nouveau/NVK ou stack compatível em uma máquina somente com GeForce suportada, incluindo inicialização, memória, filas, sincronização e triângulo Vulkan.
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
