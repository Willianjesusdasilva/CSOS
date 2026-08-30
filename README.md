# CSOS

**CSOS** é um sistema operacional experimental x86-64 escrito principalmente em **Zig**, projetado em torno de um único objetivo:

> Executar Counter-Strike 2 com o menor overhead possível do sistema operacional.

Em vez de construir um sistema operacional genérico, o CSOS concentra sua arquitetura no caminho que realmente importa para jogos:

```text
Hardware
   ↓
Kernel CSOS
   ↓
Userspace compatível com Linux
   ↓
Vulkan
   ↓
Steam
   ↓
Counter-Strike 2
```

O projeto explora como seria um sistema operacional onde performance em jogos, consistência de frametime e latência de input são prioridades arquiteturais desde o início.

---

## Filosofia

O CSOS segue uma regra simples:

```text
funciona > simples > rápido > bonito
```

O projeto evita complexidade desnecessária.

Sem arquitetura enterprise.

Sem abstrações apenas por abstração.

Sem frameworks internos gigantes.

Sem tentar reproduzir todos os recursos do Linux.

Sem reescrever componentes maduros apenas para dizer que o sistema é 100% Zig.

Toda implementação deve responder:

> Isso aproxima Steam/CS2 de funcionar ou melhora sua execução de forma mensurável?

Se não, provavelmente não pertence ao CSOS.

---

# Objetivos

Ordem de prioridade:

1. Counter-Strike 2 funcionar
2. Estabilidade
3. Frametime consistente
4. Baixa latência de input
5. Melhores 1% / 0.1% lows
6. FPS médio
7. Boot e consumo mínimos

O CSOS não pretende se tornar uma distribuição Linux de uso geral.

---

# Arquitetura

O CSOS utiliza seu próprio kernel enquanto fornece a compatibilidade Linux necessária para Steam e Counter-Strike 2.

```text
                    ┌──────────────┐
                    │     UEFI     │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Kernel CSOS  │
                    └──────┬───────┘
                           │
          ┌────────────────┼────────────────┐
          │                │                │
       Memória         Scheduler         Drivers
          │                │                │
          └────────────────┼────────────────┘
                           │
                    Userspace Linux
                       compatível
                           │
                    ┌──────▼───────┐
                    │    Vulkan    │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │    Steam     │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │     CS2      │
                    └──────────────┘
```

A compatibilidade Linux é implementada conforme os requisitos reais das aplicações, em vez de tentar reproduzir todo o kernel Linux.

---

# Linguagem

Código novo do CSOS é escrito principalmente em:

```text
Zig
```

Componentes maduros existentes em C/C++ podem ser reutilizados quando reescrevê-los não trouxer benefício relevante.

Componentes como Mesa, RADV, firmware e drivers complexos de GPU não precisam ser reescritos apenas para tornar o projeto inteiramente Zig.

---

# Hardware

Escopo inicial:

```text
x86-64
UEFI
ACPI
APIC / IOAPIC
SMP
PCIe
NVMe
xHCI
USB HID
Ethernet
USB Audio
AMD Radeon
```

AMD Radeon é o alvo inicial de GPU devido ao ecossistema gráfico aberto existente em torno de Mesa e RADV.

Suporte adicional pode ser incluído conforme surgir necessidade real.

---

# Autoconfiguração de Hardware

O CSOS foi projetado para configurar-se para a máquina onde foi instalado.

Durante a instalação:

```text
hardware discovery
        ↓
detecção de topologia
        ↓
benchmarks limitados
        ↓
seleção das melhores políticas
        ↓
hardware.csc
```

O perfil da máquina fica em:

```text
/system/config/hardware.csc
```

Ele pode armazenar decisões relacionadas a:

```text
topologia da CPU
scheduler
IRQ
input
network
NVMe
GPU
áudio
display
```

Descoberta pesada e benchmarks devem acontecer durante a instalação, não em todo boot.

O boot normal deve principalmente:

```text
validar hardware
        ↓
carregar hardware.csc
        ↓
aplicar configuração
```

Se algum hardware mudar, apenas os componentes afetados devem precisar de novo tuning.

---

# Modos de Jogo

O CSOS possui três modos:

```text
NORMAL
GAME
MATCH
```

### NORMAL

Funcionamento normal do sistema.

Downloads, diagnósticos, serviços em background e interface completa podem funcionar normalmente.

### GAME

Quando um jogo estiver rodando, o CSOS reduz atividades desnecessárias e prioriza:

```text
jogo
input
network
áudio
display
```

### MATCH

Modo competitivo.

O objetivo passa a ser:

```text
mínima interferência possível do sistema
```

Trabalho não essencial pode ser congelado, atrasado ou desligado.

---

# Standby de Aplicações

Aplicações que não estão sendo utilizadas não precisam necessariamente continuar consumindo CPU.

O CSOS utiliza um ciclo de vida:

```text
RUNNING
   ↓
BACKGROUND
   ↓
FROZEN
   ↓
STANDBY
   ↓
RESUMING
   ↓
RUNNING
```

Uma aplicação congelada deixa de participar normalmente do scheduler enquanto seu estado necessário permanece preservado.

O modo `STANDBY` também pode liberar memória que seja seguramente reconstruível.

Por exemplo, páginas limpas baseadas em arquivos podem ser descartadas e posteriormente recuperadas através de page faults normais.

```text
STANDBY
   ↓
usuário seleciona aplicação
   ↓
RESUMING
   ↓
RUNNING
   ↓
páginas são recuperadas sob demanda
```

A ideia é trazer para desktop um comportamento semelhante ao gerenciamento de aplicações de sistemas mobile, sem perder a compatibilidade necessária.

Durante `MATCH`, aplicações elegíveis em background podem ser suspensas agressivamente para não competir com o CS2.

---

# Interface Baseada em HTML

Toda a interface do CSOS é projetada em:

```text
HTML
CSS
Jinja
JavaScript mínimo
```

HTML é a linguagem utilizada para construir a interface.

Isso **não significa** que o CSOS precise executar um navegador tradicional ou servidor web.

Arquitetura:

```text
estado do sistema
     ↓
providers
     ↓
ui-runtime
     ↓
Jinja
     ↓
HTML + CSS
     ↓
renderer
     ↓
display
```

Os arquivos ficam em:

```text
/system/ui/
├── variables.conf
├── providers/
├── scripts/
└── interface/
```

Isso permite alterar completamente a interface sem recompilar o kernel.

---

# Variáveis da Interface

Informações do sistema são disponibilizadas através do `variables.conf`.

Exemplo:

```ini
CPU_TEMP="/system/ui/providers/cpu_temp"
GPU_TEMP="/system/ui/providers/gpu_temp"
CURRENT_FPS="/system/ui/providers/current_fps"
FRAME_TIME="/system/ui/providers/frame_time"
DISPLAY_REFRESH="/system/ui/providers/display_refresh"
```

Na interface:

```jinja
{{ CPU_TEMP }}
{{ GPU_TEMP }}
{{ CURRENT_FPS }}
```

Exemplo:

```html
<div class="performance">
    <span>{{ CURRENT_FPS }} FPS</span>
    <span>{{ FRAME_TIME }} ms</span>
    <span>CPU {{ CPU_TEMP }}°C</span>
    <span>GPU {{ GPU_TEMP }}°C</span>
</div>
```

Templates não podem executar comandos arbitrários.

Somente providers previamente registrados ficam disponíveis.

---

# Ações da Interface

Leitura e alteração do estado do sistema são separadas:

```text
providers → LEITURA
scripts   → AÇÃO
```

Exemplo:

```text
/system/ui/scripts/
├── launch_cs2
├── close_cs2
├── set_volume
├── set_refresh_rate
├── enable_match_mode
├── reboot
└── shutdown
```

O HTML solicita uma ação autorizada:

```html
<button data-action="launch_cs2">
    JOGAR
</button>
```

O `ui-runtime` resolve essa ação para um script autorizado.

Comandos arbitrários vindos de HTML ou JavaScript não são permitidos.

---

# Alt+Tab

O Alt+Tab do CSOS também faz parte do gerenciamento de aplicações.

Ele pode apresentar:

```text
CS2       RUNNING
Browser   STANDBY
Discord   FROZEN
Settings  STANDBY
```

Ao selecionar uma aplicação:

```text
STANDBY
   ↓
RESUMING
   ↓
RUNNING
```

A própria interface do Alt+Tab pode ser construída em HTML/CSS/Jinja.

---

# Processamento do Sistema na GPU

O CSOS também explora utilizar capacidade ociosa da GPU para workloads adequados do próprio sistema.

A prioridade é:

```text
CS2 > Display > Sistema Interativo > Compute do Sistema > Background
```

O processamento não deve ficar dentro do kernel.

Um worker em userspace será responsável:

```text
Sistema
   ↓
gpu_worker
   ↓
Vulkan Compute
   ↓
GPU
```

Possíveis workloads:

```text
hashing de grandes volumes
processamento de imagens
pré-processamento de assets
compressão/descompressão
outros workloads altamente paralelos
```

Somente tarefas que realmente apresentarem vantagem devem utilizar GPU.

O custo completo precisa ser considerado:

```text
RAM ↔ VRAM
PCIe
sincronização
latência
uso de VRAM
impacto no frametime
```

Uma GPU mostrando baixa utilização não significa automaticamente que toda capacidade restante esteja disponível sem custo.

Durante uma partida competitiva:

```text
system GPU compute = OFF
```

por padrão.

O CS2 tem prioridade.

---

# Linux ABI

O CSOS implementa a ABI Linux x86-64 necessária às aplicações.

Syscalls são adicionadas conforme requisitos reais.

Exemplos:

```text
read
write
openat
close
mmap
munmap
mprotect
brk
exit
clock_gettime
futex
epoll
sockets
ioctl
```

Regra:

> Não implementar uma syscall porque o Linux possui. Implementar porque algum software necessário ao CSOS precisa dela.

---

# Roadmap

O desenvolvimento é dividido em milestones:

```text
M0   Build
M1   Boot
M2   Memory
M3   CPU
M4   Scheduler
M5   Userspace
M6   Linux ABI
M7   BusyBox
M8   PCIe
M9   NVMe
M10  Filesystem
M11  USB/xHCI
M12  Network
M13  Audio
M14  GPU/Vulkan
M15  SDL
M16  Steam Runtime
M17  Steam
M18  CS2
M19  Hardware Discovery / Autotune
M20  Gaming Optimization
M21  Process Lifecycle
M22  Standby / Memory Reclaim
M23  HTML UI Runtime
M24  UI Actions
M25  Alt+Tab / Application UI
M26  Dynamic UI
M27  GPU Accelerated Shell
M28  GPU System Worker
M29  GPU Autotune
M30  Final Integration
```

O arquivo `GOAL.md` é a fonte de verdade técnica do roadmap e das prioridades de implementação.

---

# Estratégia de Desenvolvimento

O desenvolvimento deve seguir:

```text
identificar bloqueio atual
        ↓
implementar menor solução
        ↓
build
        ↓
boot / executar
        ↓
observar
        ↓
corrigir
        ↓
commit pequeno
        ↓
continuar
```

Não implementar dez milestones futuras antecipadamente.

Código funcional não deve ser refatorado apenas porque outra arquitetura parece mais bonita.

Otimização começa com medição.

---

# Performance

O CSOS não aceita:

```text
"parece mais rápido"
```

O processo correto é:

```text
baseline
   ↓
medir
   ↓
alterar
   ↓
medir novamente
```

Métricas relevantes:

```text
FPS
1% low
0.1% low
frametime p50 / p95 / p99
scheduler latency
input latency
network processing latency
audio underruns
CPU migrations
freeze latency
resume latency
memória recuperada
```

A própria instrumentação não deve se tornar uma fonte relevante de overhead.

---

# Anti-Cheat

O objetivo do CSOS é fornecer compatibilidade legítima com Counter-Strike 2.

O projeto nunca deve tentar:

```text
alterar VAC
hookar VAC
bypassar VAC
spoofar VAC
modificar CS2 para evitar verificações
```

Compatibilidade e performance são os objetivos.

Contornar anti-cheat não é.

---

# Estado Atual

O CSOS está em desenvolvimento experimental ativo.

As fundações do sistema operacional em desenvolvimento já incluem:

```text
boot UEFI
gerenciamento de memória
SMP
scheduler
userspace Ring 3
execução de ELF Linux
Linux ABI
BusyBox
PCIe
NVMe
filesystem
xHCI / USB HID
Ethernet
USB Audio
display
hardware profiling
```

O grande próximo desafio é a stack gráfica:

```text
GPU
↓
Vulkan
↓
SDL
↓
Steam Runtime
↓
Steam
↓
Counter-Strike 2
```

---

# Build

Fluxo principal:

```bash
zig build
```

Para executar:

```bash
zig build run
```

O target de execução deve gerar a imagem necessária e iniciar o ambiente de desenvolvimento através do QEMU.

Os requisitos exatos podem mudar enquanto o projeto estiver em desenvolvimento.

---

# Status

> **Experimental / Pré-alpha**

O CSOS ainda é um projeto de pesquisa e desenvolvimento.

Não está pronto para substituir um sistema operacional convencional e não deve ser utilizado atualmente em máquinas contendo dados importantes.

---

# Objetivo Final

O fluxo final de instalação deve ser:

```text
PC
↓
Instalador CSOS
↓
Hardware Discovery
↓
Autotune
↓
hardware.csc
↓
Boot otimizado
↓
Interface HTML
↓
Steam
↓
Counter-Strike 2
```

Durante uso normal:

```text
foreground → RUNNING
background → FREEZE / STANDBY
GPU ociosa → trabalho útil quando realmente compensar
```

Durante uma partida competitiva:

```text
                CS2
                 │
        ┌────────┼────────┐
        │        │        │
      Input   Network   Áudio
        │        │        │
        └────────┼────────┘
                 │
          Sistema Essencial
                 │
                 ▼
           Todo o restante
        congelado / reduzido
```

O CSOS existe para minimizar o caminho:

```text
hardware → kernel → Vulkan → Counter-Strike 2
```

Todo o restante precisa justificar sua existência.