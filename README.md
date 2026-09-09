# CSOS

**CSOS** é um sistema operacional experimental x86-64 escrito principalmente em **Zig**, projetado em torno de um objetivo principal:

> Executar Counter-Strike 2 com o menor overhead possível do sistema operacional, priorizando frametime consistente, baixa latência de input e previsibilidade.

O CSOS não pretende ser uma distribuição Linux genérica.

Ele utiliza seu próprio kernel e implementa a compatibilidade Linux necessária para executar software Linux existente, reutilizando componentes maduros quando isso for tecnicamente mais sensato do que reescrevê-los.

```text
Hardware
   ↓
Kernel CSOS
   ↓
Linux-compatible userspace ABI
   ↓
Mesa / drivers / Vulkan
   ↓
Steam Runtime
   ↓
Steam
   ↓
Counter-Strike 2
```

Steam e Counter-Strike 2 são deliberadamente etapas finais.

Antes deles, o CSOS deve funcionar como um sistema operacional utilizável em hardware real.

---

# Filosofia

A regra principal do projeto é:

```text
funciona > simples > rápido > bonito
```

O CSOS evita complexidade que não produza benefício real.

Isso significa:

* sem arquitetura enterprise desnecessária;
* sem abstrações apenas por abstração;
* sem frameworks internos gigantes;
* sem tentar reproduzir todos os recursos do Linux;
* sem reescrever componentes maduros apenas para dizer que tudo é Zig;
* sem otimizações baseadas apenas em teoria;
* sem declarar suporte de hardware sem validação real;
* sem esconder o funcionamento do sistema atrás de componentes opacos.

Toda implementação deve responder:

> Isso aproxima o CSOS de ser um sistema utilizável ou aproxima Steam/CS2 de funcionar corretamente e com boa performance?

Se não, provavelmente não é prioridade.

---

# Sistema experimental por design

O CSOS é deliberadamente um sistema:

```text
aberto
hackável
auditável
modificável
experimental
```

Durante o desenvolvimento, estabilidade absoluta não é um requisito.

Uma atualização pode quebrar o sistema.

Um commit pode impedir o boot.

Um driver experimental pode falhar.

Isso é aceitável desde que exista um caminho simples, previsível e independente para recuperar a máquina.

A arquitetura de desenvolvimento é baseada em três componentes:

```text
Git
│
├── versão e atualização do CSOS
│
Nix
│
├── aplicações e dependências adicionais
│
Alpine Linux
│
└── recuperação independente
```

Em resumo:

> Git atualiza o sistema.
> Nix instala software.
> Alpine recupera a máquina.

---

# Git como parte do sistema operacional

O próprio CSOS deve permanecer exposto através de Git.

Kernel, drivers, userspace específico, interface, scripts, configurações padrão e infraestrutura necessária para reproduzir uma versão devem ser derivados do repositório.

O objetivo é que o usuário consiga inspecionar o sistema instalado usando comandos Git normais.

```bash
git status
git log
git diff
git show
```

A atualização do CSOS deve ser simples:

```bash
git pull
reboot
```

Não é objetivo criar um updater proprietário que esconda o Git.

O Git é deliberadamente parte da experiência do sistema.

---

# Atualização

Uma máquina de desenvolvimento deve conseguir atualizar o CSOS aproximadamente assim:

```bash
cd /system
git pull
reboot
```

O commit atualmente instalado deve ser identificável.

O usuário também deve poder utilizar branches diferentes:

```bash
git switch dev
git pull
reboot
```

ou selecionar uma versão específica:

```bash
git checkout <commit>
reboot
```

Para restaurar completamente o estado oficial da branch:

```bash
git fetch origin
git reset --hard origin/main
reboot
```

A intenção é permitir que uma máquina CSOS acompanhe diretamente o desenvolvimento do projeto.

```text
desenvolvimento
      ↓
commit
      ↓
push
      ↓
git pull no CSOS
      ↓
reboot
      ↓
nova versão
```

---

# Separação entre sistema e dados

Arquivos controlados pelo Git são considerados reconstruíveis.

Dados do usuário e estado específico da máquina não são.

Conceitualmente:

```text
/system
│
├── kernel
├── drivers
├── userspace
├── ui
├── build
└── config/defaults

/home
/data
/nix
```

O conteúdo versionado pertence ao sistema.

O conteúdo persistente pertence à máquina ou ao usuário.

Uma operação como:

```bash
git reset --hard origin/main
```

não pode destruir:

```text
documentos
saves
downloads
configuração pessoal
pacotes Nix
estado persistente
configuração específica da máquina
```

Princípio:

> O sistema pode ser descartado e reconstruído. Os dados do usuário não.

---

# Alpine Linux Recovery

Instalações bare-metal destinadas ao desenvolvimento devem possuir um pequeno ambiente **Alpine Linux** independente.

Exemplo de layout:

```text
NVMe
│
├── EFI
├── CSOS
├── Alpine Recovery
├── /home
├── /data
└── /nix
```

O Alpine não participa da execução normal do CSOS.

Quando o CSOS está funcionando:

```text
Alpine CPU usage = 0
Alpine RAM usage = 0
```

porque ele simplesmente não está executando.

Sua função é ser o paraquedas do sistema experimental.

---

# Recuperando uma atualização quebrada

Exemplo:

```text
CSOS funcionando
       ↓
git pull
       ↓
commit experimental
       ↓
reboot
       ↓
CSOS quebra
       ↓
boot Alpine Recovery
       ↓
monta CSOS
       ↓
Git
       ↓
corrige/restaura
       ↓
reboot
       ↓
CSOS
```

No Alpine:

```bash
mount /dev/nvme0n1pX /mnt/csos

cd /mnt/csos

git status
git log
git fetch
```

Se uma correção já estiver disponível:

```bash
git pull
```

Ou para restaurar a versão oficial:

```bash
git fetch origin
git reset --hard origin/main
```

Depois:

```bash
reboot
```

---

# Recovery via SSH

O Alpine Recovery pode possuir SSH.

Isso permite transformar um notebook CSOS em uma máquina de desenvolvimento bare-metal remotamente acessível.

```text
PC / agente de desenvolvimento
             │
            SSH
             ↓
      notebook CSOS
```

Se o CSOS funcionar:

```text
SSH → CSOS
```

Se o CSOS quebrar:

```text
boot Alpine
     ↓
SSH → Alpine
     ↓
montar CSOS
     ↓
Git
     ↓
corrigir sistema
```

Isso permite que um desenvolvedor ou agente autorizado continue trabalhando mesmo quando uma alteração quebra o sistema principal.

---

# Nix

O CSOS pretende utilizar **Nix** como camada preferencial para aplicações e dependências adicionais.

Nix não substitui Git.

As responsabilidades são diferentes:

```text
Git
└── CSOS

Nix
└── aplicações e dependências

Alpine
└── recovery
```

O próprio sistema operacional continua versionado pelo Git.

Software adicional pode ser instalado pelo Nix.

Exemplo pretendido:

```bash
nix profile install nixpkgs#git
nix profile install nixpkgs#curl
nix profile install nixpkgs#htop
```

Os pacotes e suas dependências ficam principalmente em:

```text
/nix/store
```

Isso evita transformar o CSOS em uma distribuição responsável por empacotar manualmente milhares de programas.

---

# Nix e musl

O sistema base do CSOS utiliza componentes construídos para seu userspace, atualmente com forte uso de `musl`.

Isso não significa que todos os programas instalados precisem utilizar a mesma libc.

Um pacote Nix pode carregar suas próprias bibliotecas em:

```text
/nix/store
```

incluindo outra libc quando necessário.

Conceitualmente:

```text
CSOS
│
├── kernel
│
├── userspace base / musl
│
└── Linux ABI
       │
       ├── programa musl
       │
       └── programa Nix
              └── glibc própria
```

As duas continuam utilizando a ABI Linux fornecida pelo kernel CSOS.

---

# Critério de suporte ao Nix

Nix só será considerado funcional quando executar dentro do próprio CSOS.

Executar Nix no host Windows/Linux utilizado para compilar o projeto não conta.

O smoke test mínimo deve validar:

```text
filesystem
/proc
/sys
/dev
processos
exec
pipes
permissões
mmap
futex
sockets
rede
DNS
TLS
certificados
```

Depois:

```bash
nix profile install nixpkgs#hello
hello
```

e:

```bash
nix profile install nixpkgs#curl
curl https://example.com
```

também devem funcionar dentro do CSOS.

Após reboot:

```text
/nix/store
```

e os profiles instalados devem continuar disponíveis.

Não implementar compatibilidade preventivamente apenas porque Nix pode precisar dela.

A regra continua sendo:

> implementar requisitos reais encontrados durante execução real.

---

# Nix não significa Steam pronto

Fazer Nix funcionar não significa automaticamente que Steam funcionará.

Steam possui requisitos adicionais relacionados a:

```text
Linux ABI
FHS
namespaces
processos
IPC
GPU
Vulkan
áudio
input
runtime
filesystem
```

Portanto:

```text
Nix funcionando
      ≠
Steam funcionando
```

Steam continua sendo uma milestone posterior.

---

# Arquitetura

O CSOS utiliza seu próprio kernel enquanto fornece a compatibilidade Linux necessária às aplicações.

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
       Memory          Scheduler         Drivers
          │                │                │
          └────────────────┼────────────────┘
                           │
                  Linux-compatible ABI
                           │
             ┌─────────────┴─────────────┐
             │                           │
       CSOS userspace                  Nix
             │                           │
             └─────────────┬─────────────┘
                           │
                         Vulkan
                           │
                         Steam
                           │
                          CS2
```

A compatibilidade Linux é implementada conforme requisitos reais.

O objetivo não é reproduzir todo o kernel Linux.

---

# Linguagem

Código novo específico do CSOS é escrito principalmente em:

```text
Zig
```

Isso não significa que todo software utilizado pelo sistema precisa ser reescrito em Zig.

Componentes maduros existentes em C/C++ podem e devem ser reutilizados quando uma reimplementação não trouxer benefício mensurável.

Exemplos:

```text
WebKit
Mesa
RADV
NVK
libdrm
musl
bibliotecas de userspace
```

A linguagem é uma ferramenta, não um objetivo.

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
NVIDIA GeForce
```

O objetivo inicial não é suportar todo hardware existente.

O suporte deve crescer baseado em hardware real e casos concretos.

---

# AMD e NVIDIA

AMD Radeon e NVIDIA GeForce são requisitos oficiais.

AMD permanece como primeiro backend de referência devido ao ecossistema aberto envolvendo:

```text
AMDGPU
Mesa
RADV
```

NVIDIA deve utilizar a stack madura tecnicamente apropriada, como:

```text
Nouveau
NVK
```

ou componentes oficiais redistribuíveis quando necessários e compatíveis com o projeto.

A ordem de implementação é:

```text
infraestrutura DRM/KMS compartilhada
              ↓
AMD/RADV
              ↓
triângulo Vulkan em AMD real
              ↓
NVIDIA/NVK
              ↓
triângulo Vulkan em NVIDIA real
```

Essa ordem não torna NVIDIA opcional.

---

# O que significa suporte de GPU

Detectar uma GPU no PCI não significa suportá-la.

Framebuffer também não significa suporte Vulkan.

Uma GPU somente será considerada suportada depois de validar em hardware real:

```text
inicialização
display
memória
filas
sincronização
command submission
Vulkan
```

O gate final mínimo é:

```text
triângulo Vulkan real
```

A máquina NVIDIA deve funcionar sem uma Radeon presente.

A máquina AMD deve funcionar sem uma NVIDIA presente.

Sistemas híbridos devem escolher explicitamente a GPU utilizada.

---

# Autoconfiguração de hardware

O CSOS deve configurar-se para a máquina onde foi instalado.

Durante a instalação:

```text
hardware discovery
        ↓
detecção de topologia
        ↓
benchmarks limitados
        ↓
seleção de políticas
        ↓
hardware.csc
```

Configurações padrão ficam versionadas:

```text
/system/config/defaults/
```

Configurações específicas da máquina ficam fora do checkout Git:

```text
/data/config/hardware.csc
```

Isso permite:

```bash
git reset --hard
```

sem destruir o tuning daquela máquina.

O perfil pode armazenar decisões relacionadas a:

```text
CPU
scheduler
IRQ
input
network
NVMe
GPU
áudio
display
```

Benchmarks pesados não devem executar em todo boot.

Boot normal:

```text
validar hardware
      ↓
carregar hardware.csc
      ↓
aplicar configuração
```

Se o hardware mudar, apenas os componentes afetados devem precisar de novo tuning.

---

# Interface: WebKit obrigatório

O desktop do CSOS deve ser implementado em:

```text
HTML
CSS
JavaScript
```

com **WebKit executando dentro do userspace do CSOS**.

A base escolhida é:

```text
WPE WebKit
```

O WebKit existente será reutilizado.

Não será reescrito em Zig.

O kernel e a integração específica do CSOS continuam prioritariamente Zig.

---

# Critério real de WebKit

Não conta como integração:

```text
abrir um arquivo HTML
parser HTML próprio
renderizar tags manualmente
mostrar preview no Windows
mostrar preview no Linux host
desenhar HTML sem WebKit
```

WebKit só será considerado integrado quando executar dentro do próprio CSOS.

A validação deve comprovar pelo menos:

```text
WebKit executando
      ↓
HTML
      ↓
CSS
      ↓
JavaScript
      ↓
DOM
      ↓
input real
      ↓
backend CSOS
```

O runtime HTML próprio existente permanece apenas como bootstrap/fallback enquanto essa integração não estiver concluída.

---

# Estado do port WPE WebKit

O trabalho atual está construindo a cadeia necessária para executar WPE WebKit no userspace alvo do CSOS.

A cadeia cross-compilada para `x86_64-linux-musl` já avançou por componentes como:

```text
GLib
libffi
PCRE2
libWPE
libsoup
ICU
HarfBuzz
libjpeg-turbo
Epoxy
libgcrypt
libgpg-error
nghttp2
libpsl
SQLite
libtasn1
xkbcommon
libxml2
libpng
libwebp
```

Ferramentas host necessárias durante a geração do build também fazem parte da separação host/target.

O gate `glib-compile-resources` já foi atravessado no ambiente de desenvolvimento atual.

O próximo gate identificado pelo CMake é:

```text
Cairo >= 1.16
```

A progressão esperada é:

```text
dependências
      ↓
CMake WebKit completo
      ↓
WTF
      ↓
JavaScriptCore
      ↓
WebCore
      ↓
WPE
      ↓
primeiro processo WebKit no CSOS
```

Adicionar dependências somente é progresso quando o erro/gate do WebKit realmente avança.

---

# Interface baseada em HTML

A interface do CSOS deve permanecer editável sem recompilar o kernel.

Estrutura conceitual:

```text
/system/ui/
│
├── variables.conf
├── engine.conf
├── providers/
├── scripts/
├── interface/
│   ├── desktop.manifest
│   ├── apps.manifest
│   └── apps/
└── styles/
```

Arquitetura:

```text
estado do sistema
      ↓
providers
      ↓
backend CSOS
      ↓
WPE WebKit
      ↓
HTML + CSS + JavaScript
      ↓
display
```

---

# Variáveis da interface

Informações do sistema são expostas através de providers controlados.

Exemplo:

```ini
CPU_TEMP="/system/ui/providers/cpu_temp"
GPU_TEMP="/system/ui/providers/gpu_temp"
CURRENT_FPS="/system/ui/providers/current_fps"
FRAME_TIME="/system/ui/providers/frame_time"
DISPLAY_REFRESH="/system/ui/providers/display_refresh"
```

A interface pode utilizar:

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

Templates não devem executar comandos arbitrários.

---

# Ações da interface

Leitura e escrita são separadas:

```text
providers → leitura
scripts   → ação
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

HTML/JavaScript solicita uma ação autorizada.

O backend decide se ela pode ser executada.

Comandos arbitrários vindos da página não são permitidos.

---

# Alt+Tab

O Alt+Tab também faz parte do gerenciamento de aplicações.

Exemplo:

```text
CS2       RUNNING
Browser   STANDBY
Discord   FROZEN
Settings  STANDBY
```

A interface visual pode ser implementada em HTML/CSS/JavaScript.

O compositor continua responsável por:

```text
surfaces
foco
input
damage
apresentação
lifecycle
```

---

# Standby de aplicações

Aplicações não utilizadas não precisam continuar competindo com o jogo.

Lifecycle:

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

Uma aplicação congelada deixa de competir normalmente pelo scheduler.

Páginas reconstruíveis podem ser descartadas.

```text
STANDBY
   ↓
selecionar aplicação
   ↓
RESUMING
   ↓
page faults
   ↓
estado reconstruído
   ↓
RUNNING
```

O objetivo é aproximar o gerenciamento de aplicações desktop da eficiência encontrada em sistemas mobile sem quebrar compatibilidade necessária.

---

# Modos do sistema

O CSOS possui três modos:

```text
NORMAL
GAME
MATCH
```

## NORMAL

Sistema completo.

Podem executar normalmente:

```text
downloads
Nix
Git
diagnósticos
serviços
interface
background tasks
```

## GAME

Quando um jogo está executando, o sistema prioriza:

```text
jogo
input
network
áudio
display
```

Atividades desnecessárias são reduzidas.

## MATCH

Modo competitivo.

Objetivo:

```text
mínima interferência possível do sistema
```

Processos não essenciais podem ser:

```text
congelados
atrasados
suspensos
desativados
```

Git, Nix e mecanismos de atualização não devem executar automaticamente durante MATCH.

---

# Processamento do sistema na GPU

O CSOS pode explorar capacidade ociosa da GPU para workloads adequados.

Prioridade:

```text
CS2
 >
Display
 >
Sistema interativo
 >
Compute do sistema
 >
Background
```

Compute do sistema deve ocorrer em userspace.

```text
CSOS
 ↓
gpu_worker
 ↓
Vulkan Compute
 ↓
GPU
```

Possíveis workloads:

```text
hashing
processamento de imagens
assets
compressão
descompressão
tarefas altamente paralelas
```

Nenhuma tarefa deve ser enviada à GPU apenas porque a GPU está aparentemente ociosa.

Devem ser medidos:

```text
RAM ↔ VRAM
PCIe
sincronização
latência
VRAM
frametime
```

Durante MATCH:

```text
system GPU compute = OFF
```

por padrão.

---

# Linux ABI

O CSOS implementa a ABI Linux x86-64 conforme necessidades reais.

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
poll
ppoll
epoll
sockets
ioctl
```

Outros contratos necessários incluem progressivamente:

```text
scheduler
afinidade
resource limits
credenciais
sinais
wait
prctl
readv/writev
statx
statfs
getrandom
rseq
filesystem mutations
```

Regra:

> Não implementar uma syscall porque Linux possui. Implementar porque algum software necessário ao CSOS precisa dela.

Nix, WebKit, Mesa, Steam e CS2 serão importantes fontes reais para descobrir essas necessidades.

---

# SSH e desenvolvimento em hardware real

Uma instalação CSOS destinada ao desenvolvimento deve eventualmente oferecer SSH.

Isso permite:

```text
agente / desenvolvedor
        ↓
       SSH
        ↓
      CSOS
        ↓
logs / build / testes
        ↓
hardware real
```

O objetivo é reduzir a dependência de testes exclusivamente em QEMU.

Hardware real é especialmente importante para:

```text
ACPI
NVMe
USB
Ethernet
Wi-Fi
áudio
GPU
Vulkan
suspend
battery
touchpad
```

---

# Ciclo remoto de desenvolvimento

O fluxo desejado é:

```text
alterar código
     ↓
commit
     ↓
push
     ↓
SSH notebook
     ↓
git pull
     ↓
reboot
     ↓
CSOS
     ↓
smoke tests
     ↓
logs
```

Se quebrar:

```text
CSOS não inicia
      ↓
Alpine Recovery
      ↓
SSH
      ↓
Git
      ↓
restaurar/corrigir
      ↓
reboot
```

Isso transforma uma máquina física em um laboratório bare-metal para desenvolvimento contínuo.

---

# Instalação bare-metal

O objetivo mínimo do instalador é:

```text
USB UEFI
   ↓
CSOS installer
   ↓
detectar NVMe
   ↓
particionar
   ↓
instalar CSOS
   ↓
instalar Alpine Recovery
   ↓
configurar boot
   ↓
hardware discovery
   ↓
hardware.csc
   ↓
reboot
```

Depois:

```text
UEFI
│
├── CSOS
└── CSOS Recovery
```

O boot padrão é CSOS.

Recovery somente é utilizado quando necessário.

---

# Critério de instalação funcional

Uma instalação bare-metal não está concluída apenas porque arquivos foram copiados.

Deve validar:

```text
instalar
↓
reboot
↓
CSOS inicia pelo NVMe
↓
filesystem funciona
↓
input funciona
↓
rede funciona
↓
Git funciona
↓
SSH funciona
↓
git pull
↓
reboot
↓
nova versão inicia
```

Também deve existir teste negativo:

```text
versão quebrada
↓
CSOS não inicia
↓
boot Alpine
↓
montar CSOS
↓
Git
↓
restaurar versão funcional
↓
reboot
↓
CSOS inicia
```

---

# Roadmap

O desenvolvimento é dividido em milestones.

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

M14  GPU AMD/NVIDIA + Vulkan
M15  SDL
M16  Hardware Discovery / Autotune
M17  Gaming Optimization
M18  Process Lifecycle
M19  Standby / Memory Reclaim

M20  WPE WebKit Runtime
M21  UI Actions / Backend
M22  Alt+Tab / Application UI
M23  Dynamic UI

M24  GPU Accelerated Shell
M25  GPU System Worker
M26  GPU Autotune

M27  Bare-metal Install + Git Update + Alpine Recovery
M28  Nix
M29  Steam Runtime
M30  Steam
M31  Counter-Strike 2
M32  Final Integration
```

A numeração pode evoluir conforme milestones existentes forem reorganizadas, mas a dependência lógica deve permanecer.

---

# Ordem real de prioridade

A ordem conceitual é:

```text
BOOT
 ↓
MEMÓRIA
 ↓
PROCESSOS
 ↓
FILESYSTEM
 ↓
INPUT
 ↓
REDE
 ↓
ÁUDIO
 ↓
DISPLAY
 ↓
UI / WEBKIT
 ↓
INSTALAÇÃO BARE-METAL
 ↓
GIT UPDATE
 ↓
ALPINE RECOVERY
 ↓
SSH
 ↓
NIX
 ↓
GPU / VULKAN COMPLETAMENTE VALIDADO
 ↓
OTIMIZAÇÕES
 ↓
STEAM RUNTIME
 ↓
STEAM
 ↓
CS2
```

Algumas dessas frentes podem avançar em paralelo quando não houver dependência técnica direta.

Steam e CS2 não devem antecipar a construção de um sistema operacional utilizável.

---

# Estado atual

O CSOS já possui fundações significativas de:

```text
boot UEFI
memória
CPU/SMP
scheduler
userspace
Linux ABI inicial
BusyBox
PCIe
NVMe
filesystem FAT
USB/xHCI
HID
rede
áudio inicial
DRM/GPU infrastructure
SDL software
compositor
janelas
input gráfico
terminal gráfico
FILES
HTML bootstrap
```

Existem testes host e QEMU cobrindo diversas partes dessas fundações.

Isso não significa que todas estejam completamente validadas em hardware físico.

---

# Sessão gráfica atual

O caminho gráfico experimental já possui conceitos como:

```text
WindowManager
janelas
foco
hit-test
composição
mouse
teclado
Alt+Tab
minimize
maximize
resize
launcher
terminal
monitor
system
files
```

Esse compositor nativo não substitui o requisito final de WebKit.

Ele é infraestrutura do sistema e bootstrap para permitir desenvolvimento enquanto o WPE WebKit é portado.

---

# Terminal

O terminal gráfico já evoluiu de uma demonstração para um frontend de operações reais do sistema.

A direção é que ele permita executar ferramentas reais do userspace.

Exemplos existentes ou planejados:

```text
ls
cat
stat
rm
cp
mv
touch
echo
run
```

O objetivo final é permitir também:

```text
git
nix
ssh
diagnósticos
build tools
```

conforme a ABI necessária estiver disponível.

---

# Filesystem

O filesystem deve suportar de forma confiável operações necessárias ao próprio desenvolvimento.

Isso inclui progressivamente:

```text
open
read
write
append
create
delete
rename
copy
directories
metadata
permissions
links
filesystem mounting
```

FAT continua útil para bootstrap e testes.

O filesystem utilizado na instalação bare-metal final deve ser escolhido conforme os requisitos reais de Git, Nix, Steam e desenvolvimento.

---

# Performance

O CSOS não assume que possuir menos código automaticamente significa ser mais rápido.

Performance precisa ser medida.

As principais métricas são:

```text
input latency
frametime
1% low
0.1% low
FPS médio
scheduler jitter
network latency
DPC/IRQ equivalent cost
memory pressure
boot time
background CPU
```

A prioridade é:

```text
consistência
   >
latência
   >
1% lows
   >
FPS médio
```

Uma otimização que aumenta FPS médio mas piora frametime pode ser rejeitada.

---

# Baseline

O CSOS deve ser comparado contra sistemas reais.

Idealmente:

```text
Windows
Linux otimizado
CSOS
```

utilizando:

```text
mesmo hardware
mesma resolução
mesmas configurações
mesmo mapa/cenário
mesma versão do jogo
```

Sem baseline reproduzível não existe afirmação séria de ganho de performance.

---

# Princípio de validação

O projeto distingue:

```text
IMPLEMENTADO
TESTADO NO HOST
TESTADO EM QEMU
TESTADO EM HARDWARE
VALIDADO
```

Esses estados não são equivalentes.

Exemplo:

```text
GPU detectada
≠
GPU inicializada
≠
Vulkan funcionando
≠
Steam funcionando
≠
CS2 funcionando
```

A documentação deve refletir o estado real.

---

# Definition of Done

O CSOS somente poderá ser considerado funcionalmente completo quando conseguir, em hardware real suportado:

```text
boot
↓
hardware discovery
↓
filesystem
↓
input
↓
rede
↓
áudio
↓
display
↓
WebKit UI
↓
Git
↓
SSH
↓
Nix
↓
Vulkan
↓
Steam Runtime
↓
Steam
↓
CS2
↓
partida completa
```

E também:

```text
git pull
↓
reboot
↓
nova versão
```

com recuperação possível através de:

```text
Alpine Recovery
↓
Git
↓
CSOS restaurado
```

---

# O que o CSOS não pretende ser

O CSOS não pretende:

```text
substituir Linux para uso geral
suportar todo hardware existente
possuir milhares de pacotes próprios
reimplementar todo GNU/Linux
reescrever WebKit
reescrever Mesa
reescrever drivers modernos sem necessidade
ser uma distribuição tradicional
ser imutável
ser impossível de quebrar
```

Ele pretende ser:

```text
pequeno
direto
aberto
hackável
recuperável
mensurável
orientado a jogos
```

---

# Princípio final

A arquitetura do projeto pode ser resumida assim:

```text
              ┌──────────────┐
              │     Git      │
              │ fonte verdade│
              └──────┬───────┘
                     │
                     ▼
              ┌──────────────┐
              │     CSOS     │
              │ experimental │
              └──────┬───────┘
                     │
          ┌──────────┼──────────┐
          │          │          │
          ▼          ▼          ▼
        Nix       WebKit      Vulkan
          │          │          │
          ▼          ▼          ▼
        Apps         UI        Steam
                                │
                                ▼
                               CS2

Se CSOS quebrar:

              ┌──────────────┐
              │    Alpine    │
              │   Recovery   │
              └──────┬───────┘
                     │
                    Git
                     │
                     ▼
                   CSOS
```

Em uma frase:

> **CSOS é um sistema operacional experimental para jogos onde Git é a fonte da verdade, Nix fornece o ecossistema de software e Alpine garante que experimentar e quebrar o sistema continue sendo barato.**

---

# Desenvolvimento

O `GOAL.md` é a fonte de verdade técnica para prioridades, critérios de aceitação e Definition of Done.

O README descreve a arquitetura e a filosofia do projeto.

Implementações devem seguir o estado real do código e das validações.

Não aumentar porcentagens ou declarar milestones concluídas apenas porque documentação, stubs ou testes de host foram adicionados.

O que importa é o caminho funcional:

```text
código
 ↓
build
 ↓
boot
 ↓
execução real
 ↓
hardware real
 ↓
medição
```

---

# Licença

A licença do CSOS e as licenças dos componentes reutilizados devem ser respeitadas individualmente.

Componentes externos como WebKit, Mesa, bibliotecas do userspace, Nix e Alpine Linux mantêm suas respectivas licenças e não se tornam código próprio do CSOS apenas por participarem da arquitetura.

---

# Status

O CSOS está em desenvolvimento ativo e deve ser considerado:

```text
EXPERIMENTAL
```

Não utilize como único sistema de uma máquina contendo dados importantes.

Durante o desenvolvimento bare-metal, mantenha o **Alpine Recovery** disponível.

Quebrar faz parte do processo.

Conseguir entender, recuperar e continuar rapidamente também faz parte da arquitetura.
