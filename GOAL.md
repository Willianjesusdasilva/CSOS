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
- [ ] **M14 — GPU AMD/NVIDIA + Vulkan:** parcial. A preparação AMD GFX11, a ABI DRM até caches GL2, capacidade PCIe combinada, contrato GPUVA de 48 bits, tipo/largura de VRAM via ATOM, clocks e snapshots físicos de CUs/RBs/TCC ativos possuem implementação e testes de host, mas MALL/shadow/CSA/userq, execução Radeon real e triângulo RADV ainda faltam. NVIDIA/NVK vem depois do primeiro triângulo AMD e também exige validação real.
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

Snapshot em 2026-09-01, ponderado por funcionalidade real:

```text
concluído: aproximadamente 40%
restante:  aproximadamente 60%
```

Esta porcentagem não é uma contagem simples de milestones. M0–M13 têm bases relevantes, mas M14 ainda não possui triângulos Vulkan validados em AMD e NVIDIA, e M15–M30 permanecem majoritariamente pendentes. Código preparatório ou teste no host não equivale a hardware funcional.

## Próxima rota

1. Completar MALL/shadow/CSA/userq do `AMDGPU_INFO_DEV_INFO`, command submission e RADV no caminho AMD GFX11.
2. Validar o primeiro triângulo AMD/RADV em Radeon real suportada.
3. Adaptar a infraestrutura compartilhada para NVIDIA e validar Nouveau/NVK ou stack compatível em GeForce real suportada.
4. Completar SDL, autoconfiguração, estabilidade, lifecycle e interface do SO.
5. Somente então trabalhar em Steam Runtime, Steam e CS2.

## Definition of Done

O projeto só está completo quando uma instalação reproduzível em máquina suportada comprovar:

```text
UEFI boot + SMP + memória + userspace
Linux ELF e ABI necessária
NVMe + filesystem
USB mouse/teclado + rede + áudio + display
AMD/RADV Vulkan em hardware real
NVIDIA/NVK ou stack compatível Vulkan em hardware real
hardware discovery + hardware.csc + autotune
GAME/MATCH + freeze/standby/reclaim/resume
interface do sistema funcional
Steam Runtime + Steam + login/download
CS2 offline + online + partida completa
integração estável e performance medida
```

Até todos esses critérios passarem, o GOAL permanece ativo.
