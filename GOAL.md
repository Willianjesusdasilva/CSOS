# GOAL.md — CSOS

## Objetivo

Construir o **CSOS**, um sistema operacional x86-64 minimalista escrito em **Zig**, criado exclusivamente para executar **Steam + Counter-Strike 2** com o menor overhead possível.

Prioridades:

1. CS2 funcionar.
2. estabilidade.
3. frametime consistente.
4. baixa latência de input.
5. 1% / 0.1% lows.
6. FPS médio.
7. boot e consumo mínimos.

Não criar um SO genérico.

Fluxo final:

```text
UEFI
 ↓
CSOS
 ↓
Linux-compatible userspace
 ↓
Steam
 ↓
Vulkan
 ↓
CS2
```

---

## Regra principal para a IA

**Gastar o mínimo de tokens e código possível.**

Não fazer:

- testes automáticos extensos;
- mocks;
- frameworks internos;
- abstrações prematuras;
- arquitetura "enterprise";
- interfaces para uma única implementação;
- wrappers inúteis;
- documentação repetitiva;
- refactors cosméticos;
- boilerplate;
- código "bonito" sem benefício;
- suporte a hardware não necessário;
- features não exigidas pela milestone atual.

Não escrever código apenas para demonstrar boas práticas.

Preferir:

```text
funciona > simples > rápido > bonito
```

Implementar somente o menor código necessário para desbloquear a próxima etapa.

Testes devem ser principalmente:

```text
build
boot
executar
observar
corrigir
```

Criar teste automatizado somente quando ele evitar claramente trabalho manual recorrente ou regressão difícil de detectar.

---

# Linguagem

Código próprio:

```text
Zig
```

Código externo pode continuar em C/C++ quando reescrevê-lo não aproximar CS2 de funcionar.

Não reescrever Mesa, RADV, firmware ou drivers complexos apenas para dizer que o sistema é 100% Zig.

Não converter Linux linha por linha.

Preservar a ABI necessária ao userspace Linux, não a arquitetura interna do Linux.

---

# Filosofia

Pergunta que decide qualquer implementação:

> Isso aproxima Steam/CS2 de funcionar ou melhora de forma mensurável sua execução?

Se não:

```text
não fazer
```

---

# Hardware autoconfigurado

O mesmo kernel deve funcionar em diferentes máquinas suportadas.

O kernel NÃO será recompilado para cada PC.

Durante a instalação, CSOS deve:

```text
detectar hardware
↓
detectar topologia
↓
medir apenas o necessário
↓
escolher configuração
↓
gerar perfil pequeno
```

Arquivo:

```text
/system/config/hardware.csc
```

Nos boots seguintes:

```text
UEFI
↓
kernel
↓
validar hardware
↓
carregar hardware.csc
↓
aplicar configuração
↓
iniciar sistema
```

Não repetir benchmarks pesados em todo boot.

---

# hardware.csc

Começar com formato textual simples.

Não criar parser complexo.

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

Esses valores são exemplos.

Nunca inventar valores da máquina.

---

# Hardware discovery

Na instalação detectar somente dados úteis:

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
VRAM quando disponível
driver necessário
Vulkan capabilities relevantes
```

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
    ↓
usar perfil
```

Se diferente:

```text
safe defaults
↓
retunar somente componentes afetados
↓
atualizar hardware.csc
```

Trocar NIC não deve forçar autotune completo da CPU.

---

# Install-time vs boot-time vs runtime

Usar:

```text
hardware facts       → install-time
benchmark caro       → install-time
validação barata     → boot-time
estado variável      → runtime
```

Nunca executar benchmark pesado no boot normal.

---

# Autotuner

Implementar somente tuners que produzam benefício real.

Estrutura:

```text
installer/
└── autotune/
    ├── cpu.zig
    ├── irq.zig
    ├── input.zig
    ├── network.zig
    ├── nvme.zig
    ├── audio.zig
    └── display.zig
```

Não criar um sistema genérico de plugins.

Cada tuner:

```text
detecta
↓
testa poucas opções úteis
↓
escolhe
↓
salva resultado
```

---

# CPU / scheduler

O scheduler deve conhecer a topologia real.

Não assumir que todos os logical CPUs são iguais.

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

Não hardcodar um layout universal.

Medir antes de escolher afinidades agressivas.

---

# IRQ

Mapear:

```text
device
↓
MSI/MSI-X
↓
vector
↓
CPU
```

Objetivo:

```text
baixa latência
+
mínima interferência no CS2
```

Salvar somente a melhor configuração conhecida.

---

# Input

Input é caminho crítico.

```text
mouse
↓
xHCI
↓
IRQ
↓
HID
↓
input queue
↓
CS2
```

Suportar inicialmente:

```text
USB HID
xHCI
mouse
keyboard
```

Não aplicar:

```text
acceleration
smoothing
filtering
```

por padrão.

Respeitar polling anunciado pelo dispositivo.

---

# Network

Objetivo:

```text
latência baixa
jitter baixo
```

Não otimizar para throughput sintético máximo.

Detectar:

```text
RX/TX queues
MSI-X
RSS
interrupt moderation
offloads
```

Testar poucas configurações relevantes.

---

# NVMe

Implementar somente NVMe inicialmente.

Não implementar:

```text
IDE
SATA/AHCI
optical
```

até existir necessidade real.

Avaliar:

```text
queue count
queue depth
interrupt placement
```

Priorizar consistência de latência durante gameplay.

---

# GPU

GPU é a parte mais cara do projeto.

Não reescrever driver moderno de GPU antes de CS2 funcionar.

Primeira estratégia:

```text
CSOS
↓
compatibilidade necessária
↓
driver AMD existente
↓
Mesa
↓
RADV
↓
Vulkan
```

Priorizar AMD inicialmente.

Não criar um driver Radeon completo em Zig antes do primeiro frame Vulkan.

---

# Linux ABI

Steam/CS2 devem enxergar o ambiente necessário para executar binários Linux x86-64.

Manter números e semântica necessários das syscalls Linux.

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

Não implementar syscall porque "Linux tem".

Implementar porque um binário necessário pediu.

---

# Filesystem

Começar:

```text
initramfs
tmpfs
VFS mínimo
```

Depois integrar filesystem maduro necessário ao Steam.

Não inventar filesystem próprio.

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
USB Audio
```

Não priorizar:

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

# Estrutura mínima

```text
csos/
├── build.zig
├── GOAL.md
├── boot/
├── arch/x86_64/
├── kernel/
├── memory/
├── drivers/
├── fs/
├── net/
├── linux_abi/
├── gaming/
├── installer/
│   └── autotune/
├── userspace/
└── tools/
```

Criar novos diretórios somente quando realmente necessários.

---

# Milestones

Executar nesta ordem.

## M0 — Build

```text
zig build
zig build run
```

`zig build run` deve criar imagem e iniciar QEMU.

## M1 — Boot

```text
UEFI
serial
framebuffer
kernel entry
panic
```

Resultado:

```text
CSOS booting
```

## M2 — Memory

```text
physical allocator
paging
virtual memory
heap
```

## M3 — CPU

```text
GDT
IDT
exceptions
APIC
IOAPIC
timer
SMP
```

## M4 — Scheduler

```text
threads
context switch
preemption
per-CPU queues
```

Primeiro correto. Otimizar depois.

## M5 — Userspace

```text
ring 3
process
address space
syscall
ELF
```

Resultado:

```text
Hello from userspace
```

## M6 — Linux ABI básico

Executar ELF Linux estático.

## M7 — BusyBox

Meta:

```text
/bin/sh
ls
cat
echo
```

## M8 — PCIe

Enumerar hardware real.

## M9 — NVMe

Ler/escrever disco.

## M10 — Filesystem

Montar filesystem útil.

## M11 — USB/xHCI

Mouse e teclado.

## M12 — Network

Ethernet + IPv4 + UDP/TCP + DNS + DHCP.

## M13 — Audio

Primeiro USB Audio.

## M14 — GPU/Vulkan

Primeiro objetivo:

```text
Vulkan triangle
```

## M15 — SDL

Vídeo + input + áudio.

## M16 — Steam Runtime

Corrigir ABI conforme erros reais.

## M17 — Steam

```text
abre
login
biblioteca
download
```

## M18 — CS2

```text
processo inicia
↓
menu
↓
mapa offline
↓
servidor online
↓
partida completa
```

## M19 — Otimização

Somente depois de CS2 funcional.

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
diagnóstico
```

GAME:

```text
reduzir background
aplicar scheduler profile
aplicar IRQ profile
priorizar input/network/audio/game
```

MATCH:

```text
mínimo absoluto de atividade administrativa
```

Nunca interromper tarefas críticas do jogo.

---

# Métricas

Não criar sistema enorme de observabilidade.

Ter somente métricas úteis:

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
```

Instrumentação deve poder ser desligada no modo competitivo.

---

# Performance

Não aceitar "parece mais rápido".

Para otimizações importantes:

```text
antes
↓
medir
↓
alterar
↓
medir
```

Não precisa criar suíte automática.

Uma ferramenta simples de benchmark é suficiente.

---

# Código

Preferir:

```text
funções pequenas
structs simples
enums
estado explícito
poucas dependências
poucas allocations
```

Evitar:

```text
framework
DI
event bus genérico
plugin system
macro complexa
metaprogramação desnecessária
camadas artificiais
```

Não perseguir limite arbitrário de linhas por arquivo.

Dividir arquivo somente quando melhorar trabalho real.

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

Preferir:

```text
ring buffers
pools
per-CPU state
buffers pré-alocados
```

Não escrever estruturas lock-free sofisticadas sem gargalo medido.

---

# Segurança mínima obrigatória

Não sacrificar isolamento básico.

Manter:

```text
kernel/user separation
NX
W^X quando possível
validação de ponteiro de userspace
bounds
overflow checks críticos
IOMMU quando útil
```

Não criar infraestrutura de segurança enterprise.

---

# Anti-cheat

Nunca:

```text
alterar VAC
hookar VAC
bypassar VAC
spoofar VAC
modificar CS2 para contornar verificações
```

Objetivo é compatibilidade legítima.

---

# Regra de dependências

Antes de adicionar qualquer dependência:

> Ela é necessária para chegar ao CS2 funcional?

Se não:

```text
não adicionar
```

---

# Regra de implementação da IA

Antes de cada mudança:

```text
1. identificar milestone atual
2. identificar bloqueio real
3. implementar menor solução possível
4. build
5. boot/executar
6. corrigir até funcionar
7. commit pequeno
8. seguir
```

Não planejar dez milestones de código antecipadamente.

Não gerar centenas de linhas de documentação depois de cada alteração.

Atualizar este GOAL somente quando arquitetura/objetivo realmente mudar.

---

# Regra de falha

Quando algo não funcionar:

```text
reproduzir
↓
localizar camada
↓
corrigir causa
```

Não mascarar erro com fallback aleatório.

Fallback é permitido somente para manter boot seguro.

---

# Definition of Done

CSOS funcional quando:

```text
UEFI boot
SMP
memory
userspace
Linux ELF
ABI necessária
NVMe
filesystem
USB mouse/keyboard
Ethernet
audio
GPU
Vulkan
Steam
login
download
CS2
mapa offline
online
áudio
input
partida completa
```

---

# Definition of Optimized

Depois:

```text
hardware.csc confiável
CPU topology aware
IRQ tuning
input tuning
network tuning
NVMe tuning
audio tuning
GAME mode
MATCH mode
frametime melhor que baseline
input latency melhor que baseline
```

O objetivo não é obter o maior número de tweaks.

É encontrar a menor configuração que produz o melhor comportamento medido.

---

# Objetivo final

Transformar qualquer máquina **suportada**:

```text
PC
↓
instalação CSOS
↓
hardware discovery
↓
autotune
↓
hardware.csc
↓
kernel configurado para aquela máquina
↓
Steam
↓
CS2
```

O kernel deve continuar pequeno.

O instalador deve fazer o trabalho caro uma vez.

O boot deve apenas validar e carregar o perfil.

O projeto existe para minimizar o caminho:

```text
hardware
↓
kernel
↓
Vulkan
↓
CS2
```

Todo código que não ajuda esse caminho deve ser questionado.
