# GOAL.md â€” CSOS

## Objetivo

Construir o **CSOS**, um sistema operacional x86-64 minimalista escrito em **Zig**, criado exclusivamente para executar **Steam + Counter-Strike 2** com o menor overhead possÃ­vel.

Prioridades:

1. CS2 funcionar.
2. estabilidade.
3. frametime consistente.
4. baixa latÃªncia de input.
5. 1% / 0.1% lows.
6. FPS mÃ©dio.
7. boot e consumo mÃ­nimos.

O trabalho deve seguir primeiro a construÃ§Ã£o de um sistema operacional funcional:
boot, memÃ³ria, processos, armazenamento, entrada, rede, Ã¡udio, display,
energia e recuperaÃ§Ã£o. Steam e CS2 permanecem nas Ãºltimas milestones e nÃ£o
devem bloquear a implementaÃ§Ã£o ou validaÃ§Ã£o das camadas fundamentais.

NÃ£o criar um SO genÃ©rico.

Fluxo final:

```text
UEFI
 â†“
CSOS
 â†“
Linux-compatible userspace
 â†“
Steam
 â†“
Vulkan
 â†“
CS2
```

---

## Regra principal para a IA

**Gastar o mÃ­nimo de tokens e cÃ³digo possÃ­vel.**

NÃ£o fazer:

- testes automÃ¡ticos extensos;
- mocks;
- frameworks internos;
- abstraÃ§Ãµes prematuras;
- arquitetura "enterprise";
- interfaces para uma Ãºnica implementaÃ§Ã£o;
- wrappers inÃºteis;
- documentaÃ§Ã£o repetitiva;
- refactors cosmÃ©ticos;
- boilerplate;
- cÃ³digo "bonito" sem benefÃ­cio;
- suporte a hardware nÃ£o necessÃ¡rio;
- features nÃ£o exigidas pela milestone atual.

NÃ£o escrever cÃ³digo apenas para demonstrar boas prÃ¡ticas.

Preferir:

```text
funciona > simples > rÃ¡pido > bonito
```

Implementar somente o menor cÃ³digo necessÃ¡rio para desbloquear a prÃ³xima etapa.

Testes devem ser principalmente:

```text
build
boot
executar
observar
corrigir
```

Criar teste automatizado somente quando ele evitar claramente trabalho manual recorrente ou regressÃ£o difÃ­cil de detectar.

---

# Linguagem

CÃ³digo prÃ³prio:

```text
Zig
```

CÃ³digo externo pode continuar em C/C++ quando reescrevÃª-lo nÃ£o aproximar CS2 de funcionar.

NÃ£o reescrever Mesa, RADV, NVK, firmware ou drivers complexos AMD/NVIDIA apenas para dizer que o sistema Ã© 100% Zig.

NÃ£o converter Linux linha por linha.

Preservar a ABI necessÃ¡ria ao userspace Linux, nÃ£o a arquitetura interna do Linux.

---

# Filosofia

Pergunta que decide qualquer implementaÃ§Ã£o:

> Isso aproxima Steam/CS2 de funcionar ou melhora de forma mensurÃ¡vel sua execuÃ§Ã£o?

Se nÃ£o:

```text
nÃ£o fazer
```

---

# Hardware autoconfigurado

O mesmo kernel deve funcionar em diferentes mÃ¡quinas suportadas.

O kernel NÃƒO serÃ¡ recompilado para cada PC.

Durante a instalaÃ§Ã£o, CSOS deve:

```text
detectar hardware
â†“
detectar topologia
â†“
medir apenas o necessÃ¡rio
â†“
escolher configuraÃ§Ã£o
â†“
gerar perfil pequeno
```

Arquivo:

```text
/system/config/hardware.csc
```

Nos boots seguintes:

```text
UEFI
â†“
kernel
â†“
validar hardware
â†“
carregar hardware.csc
â†“
aplicar configuraÃ§Ã£o
â†“
iniciar sistema
```

NÃ£o repetir benchmarks pesados em todo boot.

---

# hardware.csc

ComeÃ§ar com formato textual simples.

NÃ£o criar parser complexo.

Exemplo:

```ini
[system]
version=1
signature=...

[cpu]
logical=16
physical=8
smt=true
preferred_timer=tsc

[scheduler]
game_mask=...
system_mask=...
background_mask=...

[input]
controller=...
irq_cpu=...

[network]
controller=...
rx_cpu=...
tx_cpu=...

[nvme]
controller=...
queues=...
depth=...

[gpu]
controller=...
driver=...

[audio]
buffer_frames=...

[display]
width=...
height=...
refresh=...
```

Esses valores sÃ£o exemplos.

Nunca inventar valores da mÃ¡quina.

---

# Hardware discovery

Na instalaÃ§Ã£o detectar somente dados Ãºteis:

## CPU

```text
vendor
family/model/stepping
cores
threads
SMT
cache topology
CCD/CCX quando existir
NUMA
APIC topology
CPUID features
TSC
```

## PCIe

```text
bus/device/function
vendor/device ID
class
BAR
MSI/MSI-X
```

## GPU

```text
vendor/device
PCI address
VRAM quando disponÃ­vel
driver necessÃ¡rio
Vulkan capabilities relevantes
```

Detectar GPUs AMD Radeon e NVIDIA GeForce suportadas. Registrar revisÃ£o, subsystem IDs e capacidades PCI relevantes para selecionar corretamente driver e firmware.

## NVMe

```text
controller
namespace
queue capability
MSI-X
block size
```

## USB

```text
xHCI controllers
mouse
keyboard
audio USB
topologia
```

## NIC

```text
controller
queues
MSI-X
offloads relevantes
```

## Display

```text
EDID
resolution
refresh rate
VRR quando existir
```

---

# Hardware signature

Gerar uma assinatura usando os componentes relevantes.

No boot:

```text
assinatura atual == hardware.csc
    â†“
usar perfil
```

Se diferente:

```text
safe defaults
â†“
retunar somente componentes afetados
â†“
atualizar hardware.csc
```

Trocar NIC nÃ£o deve forÃ§ar autotune completo da CPU.

---

# Install-time vs boot-time vs runtime

Usar:

```text
hardware facts       â†’ install-time
benchmark caro       â†’ install-time
validaÃ§Ã£o barata     â†’ boot-time
estado variÃ¡vel      â†’ runtime
```

Nunca executar benchmark pesado no boot normal.

---

# Autotuner

Implementar somente tuners que produzam benefÃ­cio real.

Estrutura:

```text
installer/
â””â”€â”€ autotune/
    â”œâ”€â”€ cpu.zig
    â”œâ”€â”€ irq.zig
    â”œâ”€â”€ input.zig
    â”œâ”€â”€ network.zig
    â”œâ”€â”€ nvme.zig
    â”œâ”€â”€ audio.zig
    â””â”€â”€ display.zig
```

NÃ£o criar um sistema genÃ©rico de plugins.

Cada tuner:

```text
detecta
â†“
testa poucas opÃ§Ãµes Ãºteis
â†“
escolhe
â†“
salva resultado
```

---

# CPU / scheduler

O scheduler deve conhecer a topologia real.

NÃ£o assumir que todos os logical CPUs sÃ£o iguais.

Detectar:

```text
core
SMT sibling
cache sharing
CCD/CCX
NUMA
P/E cores quando existirem
X3D/non-X3D quando existirem
```

O perfil pode definir:

```text
game CPUs
system CPUs
background CPUs
input CPU
network CPU
audio CPU
```

NÃ£o hardcodar um layout universal.

Medir antes de escolher afinidades agressivas.

---

# IRQ

Mapear:

```text
device
â†“
MSI/MSI-X
â†“
vector
â†“
CPU
```

Objetivo:

```text
baixa latÃªncia
+
mÃ­nima interferÃªncia no CS2
```

Salvar somente a melhor configuraÃ§Ã£o conhecida.

---

# Input

Input Ã© caminho crÃ­tico.

```text
mouse
â†“
xHCI
â†“
IRQ
â†“
HID
â†“
input queue
â†“
CS2
```

Suportar inicialmente:

```text
USB HID
xHCI
mouse
keyboard
```

NÃ£o aplicar:

```text
acceleration
smoothing
filtering
```

por padrÃ£o.

Respeitar polling anunciado pelo dispositivo.

---

# Network

Objetivo:

```text
latÃªncia baixa
jitter baixo
```

NÃ£o otimizar para throughput sintÃ©tico mÃ¡ximo.

Detectar:

```text
RX/TX queues
MSI-X
RSS
interrupt moderation
offloads
```

Testar poucas configuraÃ§Ãµes relevantes.

---

# NVMe

Implementar somente NVMe inicialmente.

NÃ£o implementar:

```text
IDE
SATA/AHCI
optical
```

atÃ© existir necessidade real.

Avaliar:

```text
queue count
queue depth
interrupt placement
```

Priorizar consistÃªncia de latÃªncia durante gameplay.

---

# GPU

GPU Ã© a parte mais cara do projeto.

NÃ£o reescrever driver moderno de GPU antes de CS2 funcionar.

Primeira estratÃ©gia AMD:

```text
CSOS
â†“
compatibilidade necessÃ¡ria
â†“
driver AMD existente
â†“
Mesa
â†“
RADV
â†“
Vulkan
```

Priorizar AMD inicialmente.

NÃ£o criar um driver Radeon completo em Zig antes do primeiro frame Vulkan.

EstratÃ©gia NVIDIA:

```text
CSOS
â†“
compatibilidade necessÃ¡ria
â†“
driver NVIDIA maduro disponÃ­vel
â†“
Nouveau/NVK ou componentes oficiais redistribuÃ­veis
â†“
Vulkan
```

NVIDIA GeForce tambÃ©m faz parte do escopo oficial. Reutilizar implementaÃ§Ãµes maduras e nÃ£o criar um driver NVIDIA completo em Zig. AMD permanece como primeiro backend de referÃªncia para evitar desenvolver duas stacks incompletas em paralelo; apÃ³s o primeiro triÃ¢ngulo Vulkan, validar o mesmo caminho em hardware NVIDIA suportado antes de considerar M14 concluÃ­da.

---

# Linux ABI

Steam/CS2 devem enxergar o ambiente necessÃ¡rio para executar binÃ¡rios Linux x86-64.

Manter nÃºmeros e semÃ¢ntica necessÃ¡rios das syscalls Linux.

Implementar sob demanda.

Primeiro:

```text
read
write
openat
close
fstat
lseek
mmap
munmap
mprotect
brk
exit
exit_group
clock_gettime
nanosleep
```

Depois conforme erros reais:

```text
clone/clone3
futex
signals
epoll
poll
eventfd
timerfd
sockets
sendmsg/recvmsg
ioctl
shared memory
Unix sockets
```

NÃ£o implementar syscall porque "Linux tem".

Implementar porque um binÃ¡rio necessÃ¡rio pediu.

---

# Filesystem

ComeÃ§ar:

```text
initramfs
tmpfs
VFS mÃ­nimo
```

Depois integrar filesystem maduro necessÃ¡rio ao Steam.

NÃ£o inventar filesystem prÃ³prio.

---

# Escopo de hardware inicial

Prioridade:

```text
x86-64
UEFI
ACPI
APIC
SMP
PCIe
NVMe
xHCI
USB HID
Ethernet
AMD Radeon
NVIDIA GeForce
USB Audio
```

NÃ£o priorizar:

```text
BIOS legacy
IDE
SATA
Bluetooth
Wi-Fi
printer
webcam
hibernate
VM
containers
eBPF
server workloads
```

---

# Estrutura mÃ­nima

```text
csos/
â”œâ”€â”€ build.zig
â”œâ”€â”€ GOAL.md
â”œâ”€â”€ boot/
â”œâ”€â”€ arch/x86_64/
â”œâ”€â”€ kernel/
â”œâ”€â”€ memory/
â”œâ”€â”€ drivers/
â”œâ”€â”€ fs/
â”œâ”€â”€ net/
â”œâ”€â”€ linux_abi/
â”œâ”€â”€ gaming/
â”œâ”€â”€ installer/
â”‚   â””â”€â”€ autotune/
â”œâ”€â”€ userspace/
â””â”€â”€ tools/
```

Criar novos diretÃ³rios somente quando realmente necessÃ¡rios.

---

# Application lifecycle / standby

AplicaÃ§Ãµes fora de foco nÃ£o devem continuar competindo com o workload principal sem necessidade.

Estados:

```text
RUNNING
â†“
BACKGROUND
â†“
FROZEN
â†“
STANDBY
â†“
RESUMING
â†“
RUNNING
```

PolÃ­ticas:

```text
KEEP_ALIVE
FREEZE
STANDBY
AUTO
```

Ao perder foco:

```text
RUNNING
â†“
BACKGROUND
â†“
grace period
â†“
FROZEN
```

Freeze:

- remover threads das run queues;
- pausar execuÃ§Ã£o normal;
- preservar estado necessÃ¡rio;
- CPU do processo deve tender a zero;
- timers ficam pausados por padrÃ£o, salvo exceÃ§Ãµes necessÃ¡rias.

ApÃ³s freeze, o sistema pode fazer reclaim seguro.

Classificar pÃ¡ginas somente no nÃ­vel necessÃ¡rio:

```text
FILE_BACKED_CLEAN
FILE_BACKED_DIRTY
ANONYMOUS
SHARED
PINNED
GPU
```

`FILE_BACKED_CLEAN` pode ser descartada e recuperada depois via page fault + filesystem + NVMe.

`FILE_BACKED_DIRTY` deve ser persistida ou mantida.

`ANONYMOUS`, `SHARED`, `PINNED` e memÃ³ria ligada a GPU permanecem residentes enquanto nÃ£o existir mecanismo comprovadamente seguro para removÃª-las.

NÃ£o implementar snapshot completo de processo como requisito inicial.

Resume deve ser lazy:

```text
selecionar app
â†“
RESUMING
â†“
threads retornam
â†“
RUNNING
â†“
page faults recuperam pÃ¡ginas descartadas conforme necessÃ¡rio
```

AplicaÃ§Ãµes multiprocesso devem poder pertencer a um grupo lÃ³gico para evitar congelar apenas metade de um app.

GAME/MATCH podem aplicar standby mais agressivamente.

Durante MATCH, manter apenas o necessÃ¡rio:

```text
CS2
kernel
display/GPU
input
network
audio
Steam estritamente necessÃ¡rio
processos explicitamente autorizados
```

Todo restante deve preferencialmente ficar `FROZEN` ou `STANDBY`.

---

# Interface HTML

Toda interface do CSOS deve ser baseada em:

```text
HTML
CSS
JavaScript mÃ­nimo
Jinja
```

NÃ£o usar toolkit desktop tradicional como arquitetura principal.

HTML Ã© a linguagem da interface; isso NÃƒO exige navegador completo, servidor HTTP, Node, Python, nginx ou Apache.

Estrutura:

```text
/system/ui/
â”œâ”€â”€ variables.conf
â”œâ”€â”€ providers/
â”œâ”€â”€ scripts/
â””â”€â”€ interface/
    â”œâ”€â”€ index.html
    â”œâ”€â”€ alt_tab.html
    â”œâ”€â”€ settings.html
    â”œâ”€â”€ performance.html
    â”œâ”€â”€ css/
    â””â”€â”€ js/
```

Criar um `ui-runtime` pequeno.

Fluxo:

```text
variables.conf
â†“
providers/estado do sistema
â†“
ui-runtime
â†“
Jinja
â†“
HTML/CSS
â†“
renderer
â†“
display
```

O renderer deve fornecer somente HTML/CSS/JS necessÃ¡rio ao shell, com aceleraÃ§Ã£o GPU quando disponÃ­vel.

A interface deve poder ser alterada sem recompilar o kernel.

---

# variables.conf

O arquivo associa uma variÃ¡vel da interface a um provider/comando.

Formato inicial:

```ini
CPU_MODEL="/system/ui/providers/cpu_model"
CPU_TEMP="/system/ui/providers/cpu_temp"
GPU_MODEL="/system/ui/providers/gpu_model"
GPU_TEMP="/system/ui/providers/gpu_temp"
RAM_USED="/system/ui/providers/ram_used"
RAM_TOTAL="/system/ui/providers/ram_total"
CURRENT_FPS="/system/ui/providers/current_fps"
FRAME_TIME="/system/ui/providers/frame_time"
GAME_MODE="/system/ui/providers/game_mode"
NETWORK_IP="/system/ui/providers/network_ip"
NETWORK_PING="/system/ui/providers/network_ping"
DISPLAY_REFRESH="/system/ui/providers/display_refresh"
DISPLAY_RESOLUTION="/system/ui/providers/display_resolution"
```

Valores acima sÃ£o exemplos.

Provider simples:

```text
executar
â†“
stdout
â†“
valor
```

Na interface:

```jinja
{{ CPU_TEMP }}
{{ CURRENT_FPS }}
{{ GAME_MODE }}
```

Exemplo:

```html
<span>CPU {{ CPU_TEMP }}Â°C</span>
<span data-var="CURRENT_FPS">{{ CURRENT_FPS }} FPS</span>
```

O mesmo provider nÃ£o deve ser executado vÃ¡rias vezes no mesmo ciclo de render. Resolver uma vez e usar cache.

Valores rÃ¡pidos podem posteriormente usar acesso residente:

```ini
CPU_MODEL="exec:/system/ui/providers/cpu_model"
CURRENT_FPS="sys:game.fps"
FRAME_TIME="sys:game.frametime"
```

`exec:` executa provider.

`sys:` consulta estado jÃ¡ residente no `ui-runtime`.

Implementar `sys:` somente quando necessÃ¡rio.

Para atualizaÃ§Ã£o rÃ¡pida:

```text
runtime
â†“
IPC
â†“
JS mÃ­nimo
â†“
DOM update
```

NÃ£o rerenderizar a pÃ¡gina inteira para atualizar FPS/frametime.

Jinja nunca pode executar shell arbitrÃ¡rio.

PROIBIDO:

```jinja
{{ exec("command") }}
```

Templates acessam somente variÃ¡veis registradas.

---

# Scripts da interface

Separar leitura de aÃ§Ãµes:

```text
variables.conf/providers â†’ READ
scripts/                 â†’ ACTION
```

Exemplo:

```text
/system/ui/scripts/
â”œâ”€â”€ launch_cs2
â”œâ”€â”€ close_cs2
â”œâ”€â”€ set_volume
â”œâ”€â”€ set_resolution
â”œâ”€â”€ set_refresh_rate
â”œâ”€â”€ enable_match_mode
â”œâ”€â”€ disable_match_mode
â”œâ”€â”€ reboot
â””â”€â”€ shutdown
```

HTML:

```html
<button data-action="launch_cs2">PLAY</button>
```

A interface envia somente o nome da aÃ§Ã£o.

O runtime resolve somente scripts autorizados dentro de `/system/ui/scripts/`.

Nunca aceitar shell, path ou comando arbitrÃ¡rio vindo do HTML/JS.

---

# Alt+Tab

Alt+Tab faz parte do lifecycle manager.

Deve mostrar aplicaÃ§Ã£o/grupo e estado:

```text
CS2       RUNNING
Browser   STANDBY
Discord   FROZEN
Settings  STANDBY
```

Ao selecionar um app em standby:

```text
STANDBY
â†“
RESUMING
â†“
RUNNING
```

A UI de Alt+Tab tambÃ©m Ã© HTML/Jinja.

NÃ£o criar compositor/gerenciador visual complexo antes do mecanismo funcionar.

---

# GPU para tarefas do sistema

A GPU pode executar tarefas do sistema quando houver ganho real e quando isso nÃ£o prejudicar CS2.

Regra:

```text
CS2 > display > interactive system > system compute > background compute
```

NÃ£o colocar compute complexo no kernel.

Criar userspace:

```text
userspace/
â””â”€â”€ gpu_worker/
```

Fluxo:

```text
system request
â†“
gpu_worker
â†“
Vulkan Compute
â†“
GPU
```

Se `gpu_worker` falhar, kernel e sistema continuam.

Manter CPU fallback quando necessÃ¡rio.

Candidatos:

```text
hashing de grandes volumes
image processing
asset preprocessing
tarefas paralelas grandes
compressÃ£o/descompressÃ£o quando benchmark provar vantagem
```

NÃ£o mover para GPU:

```text
scheduler
syscalls
IRQ
USB input
timers
filesystem metadata comum
pequenos pacotes de rede
process management
```

GPU dedicada possui custo de transferÃªncia RAMâ†”VRAM/PCIe. iGPU/shared memory possui caracterÃ­sticas diferentes.

NÃ£o assumir que GPU em 30% significa 70% de compute grÃ¡tis.

Avaliar custo completo.

Budget inicial:

```text
DESKTOP â†’ HIGH
GAME    â†’ LOW
MATCH   â†’ ZERO
```

Durante MATCH, compute de sistema na GPU fica desligado por padrÃ£o.

Se futuramente houver evidÃªncia de que um workload nÃ£o afeta frametime, a polÃ­tica pode ser ajustada.

O autotuner pode comparar CPU vs GPU para workloads reais e guardar a decisÃ£o em `hardware.csc`.

Exemplo:

```ini
[gpu_jobs]
hash=gpu
compression=cpu
image=gpu
```

NÃ£o manter uma implementaÃ§Ã£o GPU se ela nÃ£o vencer a CPU no custo total relevante.

---

# Estrutura expandida

```text
csos/
â”œâ”€â”€ build.zig
â”œâ”€â”€ GOAL.md
â”œâ”€â”€ boot/
â”œâ”€â”€ arch/x86_64/
â”œâ”€â”€ kernel/
â”œâ”€â”€ memory/
â”œâ”€â”€ drivers/
â”œâ”€â”€ fs/
â”œâ”€â”€ net/
â”œâ”€â”€ linux_abi/
â”œâ”€â”€ gaming/
â”œâ”€â”€ installer/
â”‚   â””â”€â”€ autotune/
â”œâ”€â”€ userspace/
â”‚   â”œâ”€â”€ init/
â”‚   â”œâ”€â”€ ui-runtime/
â”‚   â””â”€â”€ gpu_worker/
â””â”€â”€ tools/
```

Interface instalada:

```text
/system/ui/
â”œâ”€â”€ variables.conf
â”œâ”€â”€ providers/
â”œâ”€â”€ scripts/
â””â”€â”€ interface/
```

Criar diretÃ³rios somente quando necessÃ¡rios.

---

# Milestones

A IA deve primeiro inspecionar o repositÃ³rio atual e recalcular qual milestone jÃ¡ foi concluÃ­da, qual estÃ¡ parcial e qual Ã© o prÃ³ximo bloqueio real.

NÃ£o reiniciar trabalho jÃ¡ feito.

NÃ£o seguir cegamente numeraÃ§Ã£o antiga se o cÃ³digo real estiver mais avanÃ§ado.

Manter a numeraÃ§Ã£o abaixo como rota oficial.

## M0 â€” Build

```text
zig build
zig build run
```

`zig build run` cria imagem e inicia QEMU.

## M1 â€” Boot

```text
UEFI
serial
framebuffer
kernel entry
panic
```

## M2 â€” Memory

```text
physical allocator
paging
virtual memory
heap
```

## M3 â€” CPU

```text
GDT
IDT
exceptions
APIC
IOAPIC
timer
SMP
```

## M4 â€” Scheduler

```text
threads
context switch
preemption
per-CPU queues
```

Primeiro correto. Otimizar depois.

## M5 â€” Userspace

```text
ring 3
process
address space
syscall
ELF
```

Resultado mÃ­nimo:

```text
Hello from userspace
```

## M6 â€” Linux ABI bÃ¡sico

Executar ELF Linux estÃ¡tico.

Implementar syscalls sob demanda, guiado por binÃ¡rios reais.

## M7 â€” BusyBox

Meta:

```text
/bin/sh
ls
cat
echo
```

BusyBox Ã© ferramenta de bootstrap/validaÃ§Ã£o, nÃ£o requisito permanente do produto final.

## M8 â€” PCIe

Enumerar hardware real e expor dados necessÃ¡rios ao hardware discovery.

## M9 â€” NVMe

Ler/escrever disco.

## M10 â€” Filesystem

Montar filesystem Ãºtil e fornecer base para page-backed reclaim futuro.

## M11 â€” USB/xHCI

Mouse e teclado.

## M12 â€” Network

Ethernet + IPv4 + UDP/TCP + DNS + DHCP.

## M13 â€” Audio

Primeiro USB Audio.

## M14 â€” GPU AMD/NVIDIA + Vulkan

Primeiro objetivo:

```text
Vulkan triangle
```

Reutilizar stack madura necessÃ¡ria em vez de reescrever driver moderno antes de funcionar.

Ordem interna:

```text
DRM/KMS compartilhado
â†“
AMD Radeon + RADV â†’ Vulkan triangle
â†“
NVIDIA GeForce + NVK/stack compatÃ­vel â†’ Vulkan triangle
```

Somente GPUs e geraÃ§Ãµes explicitamente validadas entram como suportadas.

Critérios obrigatórios de M14:

```text
base DRM/KMS compartilhada funcional
AMD Radeon suportada + RADV + triângulo Vulkan em hardware real
NVIDIA GeForce suportada + NVK/stack compatível + triângulo Vulkan em hardware real
```

Detecção PCI, seleção de driver ou ioctls isolados não contam como suporte 3D.
Não anunciar AMD ou NVIDIA como funcional antes da validação correspondente.
Steam/CS2 não fazem parte dos critérios de M14 e permanecem para M27-M29.

Manter uma matriz de suporte por fabricante, família de GPU e backend Vulkan.
Cada combinação AMD/RADV ou NVIDIA/NVK/stack compatível só muda para
`supported` depois de validar em hardware real inicialização, memória, filas,
sincronização e triângulo Vulkan. O trabalho NVIDIA começa depois do primeiro
triângulo AMD/RADV; ele não autoriza antecipar Steam Runtime, Steam ou CS2.

## M15 â€” SDL

VÃ­deo + input + Ã¡udio.

## M16 â€” Hardware discovery + installer autotune

Finalizar instalaÃ§Ã£o autoconfigurÃ¡vel:

```text
detectar hardware
â†“
topologia
â†“
microbenchmarks necessÃ¡rios
â†“
hardware.csc
```

Validar assinatura no boot e retunar apenas componentes alterados.

## M17 â€” Gaming optimization

Implementar e medir:

```text
CPU topology awareness
scheduler policy
IRQ placement
input tuning
network tuning
NVMe tuning
audio tuning
GAME
MATCH
```

Toda otimizaÃ§Ã£o precisa ser comparada com baseline.

## M18 â€” Process lifecycle

Implementar:

```text
RUNNING
BACKGROUND
FROZEN
RESUMING
```

Adicionar:

```text
KEEP_ALIVE
FREEZE
AUTO
```

Freeze deve remover threads das run queues e pausar timers normais.

Integrar com GAME/MATCH.

## M19 â€” Standby + memory reclaim

Adicionar:

```text
STANDBY
```

Implementar classificaÃ§Ã£o mÃ­nima de pÃ¡ginas e reclaim seguro de `FILE_BACKED_CLEAN`.

Resume deve usar page faults/lazy restore.

Adicionar polÃ­tica `STANDBY`.

NÃ£o implementar snapshot completo de processo nesta milestone.

## M20 â€” HTML UI runtime

Implementar:

```text
ui-runtime
variables.conf
providers
Jinja
HTML renderer
CSS
input
```

Meta:

```jinja
{{ CPU_TEMP }}
```

resolver um provider real e aparecer na interface.

NÃ£o usar servidor web desnecessÃ¡rio.

## M21 â€” UI actions

Implementar `/system/ui/scripts/` e `data-action`.

Meta:

```text
HTML button
â†“
aÃ§Ã£o autorizada
â†“
script
â†“
resultado
```

Nunca executar shell arbitrÃ¡rio vindo da UI.

## M22 â€” Alt+Tab / application UI

Integrar HTML UI ao lifecycle manager.

Mostrar:

```text
RUNNING
FROZEN
STANDBY
```

Selecionar app deve realizar resume quando necessÃ¡rio.

## M23 â€” Dynamic UI

Adicionar atualizaÃ§Ãµes de alta frequÃªncia sem rerender completo:

```text
runtime state
â†“
IPC
â†“
JS mÃ­nimo
â†“
DOM
```

Usar para FPS, frametime e mÃ©tricas que realmente precisam disso.

Quando necessÃ¡rio, adicionar providers `sys:` residentes.

## M24 â€” GPU accelerated shell

Acelerar renderer/composiÃ§Ã£o da UI via GPU.

Quando UI nÃ£o estiver visÃ­vel, seu trabalho deve tender a zero.

MATCH deve reduzir animaÃ§Ãµes, timers e telemetria visual.

## M25 â€” GPU system worker

Criar `userspace/gpu_worker`.

Implementar Vulkan Compute mÃ­nimo e um workload real.

Comparar:

```text
CPU
vs
GPU
```

incluindo transferÃªncia e sincronizaÃ§Ã£o.

SÃ³ manter GPU path se houver ganho mensurÃ¡vel.

## M26 â€” GPU autotune

Integrar decisÃµes de GPU compute ao autotuner/hardware.csc.

Exemplo:

```text
hash â†’ GPU
compression â†’ CPU
image â†’ GPU
```

Somente valores medidos.

GAME deve reduzir budget.

MATCH:

```text
system GPU compute = OFF
```

por padrÃ£o.

## M27 â€” Steam Runtime

Corrigir ABI conforme erros reais somente depois de o sistema operacional estar funcional e validado nas etapas anteriores.

## M28 â€” Steam

```text
abre
login
biblioteca
download
```

## M29 â€” CS2 funcional

```text
processo inicia
â†“
menu
â†“
mapa offline
â†“
servidor online
â†“
partida completa
```

Neste ponto existe uma baseline funcional obrigatÃ³ria.

## M30 â€” Final integration

Validar o sistema completo:

```text
boot
â†“
hardware profile
â†“
HTML shell
â†“
Steam
â†“
CS2
â†“
GAME/MATCH
â†“
background freeze/standby
â†“
Alt+Tab/resume
```

Nenhuma feature de UI, standby ou GPU compute pode piorar estabilidade ou performance do CS2.

---

# Gaming mode

Estados:

```text
NORMAL
GAME
MATCH
```

NORMAL:

```text
updates
downloads
diagnÃ³stico
UI completa
GPU system compute permitido conforme profile
```

GAME:

```text
reduzir background
aplicar scheduler profile
aplicar IRQ profile
priorizar input/network/audio/game
congelar processos elegÃ­veis
reduzir GPU system compute
```

MATCH:

```text
mÃ­nimo absoluto de atividade administrativa
freeze/standby agressivo
UI background quase zero
system GPU compute off por padrÃ£o
```

Nunca interromper tarefas crÃ­ticas do jogo.

---

# MÃ©tricas

NÃ£o criar sistema enorme de observabilidade.

Manter somente o necessÃ¡rio:

```text
FPS
1% low
0.1% low
frametime p50/p95/p99
scheduler latency
input latency
network processing latency
audio underruns
CPU migrations
freeze latency
resume latency
memory reclaimed
```

InstrumentaÃ§Ã£o deve poder ser reduzida/desligada em MATCH.

---

# Performance

NÃ£o aceitar "parece mais rÃ¡pido".

Para mudanÃ§a relevante:

```text
antes
â†“
medir
â†“
alterar
â†“
medir
```

NÃ£o precisa suÃ­te automÃ¡tica extensa.

Ferramentas simples bastam.

---

# CÃ³digo

Preferir:

```text
funÃ§Ãµes pequenas
structs simples
enums
estado explÃ­cito
poucas dependÃªncias
poucas allocations
```

Evitar:

```text
framework
DI
event bus genÃ©rico
plugin system
macro complexa
metaprogramaÃ§Ã£o desnecessÃ¡ria
camadas artificiais
```

NÃ£o perseguir limite arbitrÃ¡rio de linhas.

---

# Hot paths

Evitar allocation em:

```text
scheduler
IRQ
input
network RX/TX
audio
```

Preferir quando necessÃ¡rio:

```text
ring buffers
pools
per-CPU state
buffers prÃ©-alocados
```

NÃ£o criar lock-free sofisticado sem gargalo medido.

---

# SeguranÃ§a mÃ­nima

Manter:

```text
kernel/user separation
NX
W^X quando possÃ­vel
validaÃ§Ã£o de ponteiro userspace
bounds
overflow checks crÃ­ticos
IOMMU quando Ãºtil
```

Na UI:

```text
templates nÃ£o executam shell
actions usam allowlist
paths nÃ£o vÃªm do HTML
providers sÃ£o registrados
```

NÃ£o criar infraestrutura enterprise.

---

# Anti-cheat

Nunca:

```text
alterar VAC
hookar VAC
bypassar VAC
spoofar VAC
modificar CS2 para contornar verificaÃ§Ãµes
```

Objetivo Ã© compatibilidade legÃ­tima.

---

# Regra de implementaÃ§Ã£o da IA

Ao receber este GOAL atualizado:

```text
1. ler o repositÃ³rio atual
2. comparar implementaÃ§Ã£o real com M0â€“M30
3. marcar internamente concluÃ­do/parcial/faltando
4. identificar primeiro bloqueio real
5. recalcular a rota
6. continuar dali
```

NÃ£o apagar implementaÃ§Ã£o funcional sÃ³ porque a arquitetura mudou.

NÃ£o recomeÃ§ar milestones concluÃ­das.

Depois, para cada mudanÃ§a:

```text
identificar bloqueio
â†“
implementar menor soluÃ§Ã£o
â†“
build
â†“
boot/executar
â†“
observar
â†“
corrigir
â†“
commit pequeno
â†“
seguir
```

NÃ£o implementar vÃ¡rias milestones antecipadamente.

NÃ£o gastar tokens explicando o Ã³bvio.

NÃ£o gerar documentaÃ§Ã£o paralela sem necessidade.

Se descobrir que uma milestone posterior precisa vir antes por dependÃªncia tÃ©cnica real, ajustar a rota e registrar de forma curta o motivo.

---

# Definition of Done

## Current execution order

The implementation must prioritize a functional operating system before
Steam or CS2:

```text
M13 audio
M14 GPU AMD/NVIDIA + Vulkan
M15 SDL
M16-M19 hardware discovery, optimization, lifecycle and standby
M20-M26 UI, accelerated shell and optional GPU system work
M27 Steam Runtime
M28 Steam
M29 CS2
M30 final integration
```

Steam and CS2 are intentionally last. They must not be used as acceptance
criteria for earlier milestones.

Current M14 checkpoint:

```text
AMDGPU VMID isolation and logical GPUVA mapping: implemented and host-tested
GFX11 48-bit page-path and PDE/PTE encoding: implemented and host-tested
dynamic branch sharing/reference/prune plan: implemented and host-tested
dynamic physical page-table allocation/link/prune: implemented and host-tested
GEM_VA immediate GTT MAP/UNMAP software path: implemented; Radeon validation pending
MMHUB 3.0 VMID bind/unbind register transaction: implemented and host-tested
gate-controlled GEM_VA bind/invalidate/unbind lifecycle: implemented and host-tested
typed GFX11 firmware roles and MES payload validation: implemented and host-tested
GFX11 ring resource contract and fail-closed preflight: implemented and host-tested
transactional ring/MQD/EOP/pointer physical allocation: implemented and host-tested
dual MES scheduler/KIQ GART layout and GFX11 MQD encoding: implemented and host-tested
SOC21 MES ring0/ring1 doorbell assignment: implemented as a write-free plan
MES mes_2/mes fallback + mes1 typed selection: implemented; archive validation pending
MES code/data physical staging and bounded GART layout: implemented; GART layout host-tested
GFX11 MES register resolution, halted-state classification and load write-set: implemented and host-tested
dual-pipe MES load transaction with readback/rollback and explicit gate: implemented and host-tested
dual-pipe MES unhalt/version handshake with timeout-to-halt rollback: implemented and host-tested
ME3/pipe1 KIQ HQD activation transaction with doorbell-last/active-last ordering: implemented and host-tested
private GFX11 KIQ WRITE_DATA ring test with 64-bit doorbell, timeout and rollback: implemented and host-tested
KIQ MAP_QUEUES of MES scheduler with scratch/RPTR completion and halt rollback: implemented and host-tested
MES control page/GART, GFX11 HQD/VMID/aggregated-doorbell topology and typed SET_HW_RSRC frame: implemented and host-tested
direct GPUVM VMIDs 1-7 partitioned from MES-owned VMIDs 8-15: implemented and host-tested
private scheduler SET_HW_RSRC + QUERY_STATUS transaction with dual-fence/RPTR timeout-to-halt: implemented and host-tested
real Radeon MMIO lifecycle validation: pending
real MES load/handshake/KIQ/scheduler-map/SET_HW_RSRC validation and command submission: pending
AMD RADV triangle on real hardware: pending
NVIDIA NVK/compatible-stack triangle on real hardware: pending
```

The branch nodes own physical table pages and map/unmap creates, links, prunes
and releases them transactionally. GEM_VA and the gate-controlled hardware
context lifecycle now exist, but require real Radeon validation. Command
submission is still absent. M14 remains incomplete, and neither AMD nor NVIDIA
acceleration may be advertised from this checkpoint.

CSOS completo quando:

```text
UEFI boot
SMP
memory
userspace
Linux ELF
ABI necessÃ¡ria
NVMe
filesystem
USB mouse/keyboard
Ethernet
audio
GPU AMD/NVIDIA
Vulkan
Steam
login/download
CS2 offline/online
partida completa

hardware discovery
hardware.csc
autotune

GAME/MATCH

process freeze
standby
memory reclaim
lazy resume

HTML shell
variables.conf
providers
Jinja
scripts/actions
Alt+Tab
dynamic UI

GPU accelerated UI
gpu_worker quando vantajoso
```

---

# Definition of Optimized

Considerar otimizado quando houver evidÃªncia de:

```text
hardware.csc confiÃ¡vel
CPU topology aware
IRQ tuning
input tuning
network tuning
NVMe tuning
audio tuning
GAME/MATCH
background sem competiÃ§Ã£o desnecessÃ¡ria
standby funcional
resume rÃ¡pido
UI com overhead baixo
GPU compute somente onde vence CPU
frametime melhor ou igual Ã  baseline
input latency melhor ou igual Ã  baseline
```

Nenhuma otimizaÃ§Ã£o Ã© obrigatÃ³ria se benchmark mostrar piora.

Remover/desativar o que nÃ£o funcionar.

---

# Objetivo final

Transformar uma mÃ¡quina suportada em:

```text
PC
â†“
CSOS installer
â†“
hardware discovery
â†“
autotune
â†“
hardware.csc
â†“
boot otimizado
â†“
HTML shell
â†“
Steam
â†“
CS2
```

Durante uso comum:

```text
foreground â†’ RUNNING
background â†’ FREEZE/STANDBY
GPU ociosa â†’ trabalho Ãºtil somente quando compensa
```

Durante partida:

```text
CS2 primeiro
â†“
input/network/audio/display
â†“
kernel essencial
â†“
todo o resto congelado, reduzido ou desligado quando possÃ­vel
```

O kernel deve permanecer pequeno.

A interface deve permanecer simples e substituÃ­vel.

O instalador faz o trabalho caro uma vez.

O boot valida e aplica.

O sistema mede antes de otimizar.

Todo cÃ³digo que nÃ£o aproxima o CSOS desse comportamento deve ser questionado.
