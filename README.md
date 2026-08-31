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

Componentes como Mesa, RADV, NVK, firmware e drivers complexos de GPU AMD/NVIDIA não precisam ser reescritos apenas para tornar o projeto inteiramente Zig.

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

AMD Radeon continua como o primeiro backend de referência devido ao ecossistema aberto de AMDGPU, Mesa e RADV. NVIDIA GeForce também faz parte do escopo suportado, reutilizando a stack madura disponível — driver aberto/Nouveau, NVK ou componentes oficiais redistribuíveis quando tecnicamente necessários e compatíveis com o projeto.

O trabalho compartilhado de DRM/KMS, memória, sincronização e ABI deve ser reutilizado pelos dois backends. O segundo backend não deve atrasar a construção do primeiro caminho Vulkan funcional, mas M14 só estará completo após validar hardware AMD e NVIDIA suportado.

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
M14  GPU AMD/NVIDIA + Vulkan
M15  SDL
M16  Hardware Discovery / Autotune
M17  Gaming Optimization
M18  Process Lifecycle
M19  Standby / Memory Reclaim
M20  HTML UI Runtime
M21  UI Actions
M22  Alt+Tab / Application UI
M23  Dynamic UI
M24  GPU Accelerated Shell
M25  GPU System Worker
M26  GPU Autotune
M27  Steam Runtime
M28  Steam
M29  CS2
M30  Final Integration
```

Steam Runtime, Steam e CS2 são deliberadamente as últimas etapas funcionais. Antes delas, o sistema deve estar utilizável, estável e validado com display, GPU AMD/NVIDIA, SDL, hardware discovery, ciclo de processos, standby, UI e otimizações mensuráveis.

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

O trabalho atual está em M14. A base DRM/KMS compartilhada já possui nós
primary/render, buffers GEM page-backed, mmap, framebuffer, sincronização
binária/timeline e início da ABI de alocação AMDGPU. A preparação AMD também já
valida o catálogo de firmware, interpreta `ip_discovery.bin`, preserva as
versões exatas dos blocos IP, escolhe a família de backend e prepara firmware
de segurança em páginas físicas. Os pacotes PSP v1/v2 são decompostos em
componentes tipados e validados — como SYS_DRV, SOS, KDB, TOC, SPL e RL — sem
confundir o payload comum com a imagem que cada comando de boot consumirá. A
política PSP mantém a revisão MP0 exata e
distingue host boot, autoload e TMR de boot conforme o dispatcher upstream do
AMDGPU. A seleção física de SYS/SOS também preserva o caminho auxiliar exigido
pelo MP0 13.0.2 sem XGMI ligado à CPU; nessa revisão, topologia desconhecida é
rejeitada em vez de escolher firmware por suposição. Nenhuma dessas etapas,
isoladamente, representa aceleração 3D nem
suporte Vulkan concluído.

O handoff PSP é mantido declarativo: KDB, SPL, SYS_DRV e SOS são ordenados como
no fluxo upstream e apontam para suas fontes físicas validadas. Uma única área
de transferência é reservada com alinhamento de 1 MiB, necessário para o
endereço comunicado ao bootloader. A preparação não copia nem envia comandos
ao mailbox; qualquer execução depende separadamente do backend MMIO, preflight
e autorização exata do hardware no manifesto.

Uma máquina de estados controla esse handoff: apenas uma imagem pode estar
preparada ou submetida, cada submissão recebe deadline explícito e timeout torna
o fluxo terminal. A conclusão é necessária para liberar a próxima imagem. O
boot executa um autoteste com páginas físicas reais, compara as cópias SYS/SOS
e valida a progressão completa sem acessar registradores da GPU.

A progressão usa uma interface de transporte PSP separada, limitada a consultar
se o sOS já está vivo, submeter um descritor preparado e observar seu estado.
O autoteste fornece um transporte simulado e cobre conclusão, bypass de sOS já
ativo e recusa de submissão. Adaptadores de mailbox por família ainda não estão
habilitados; portanto essa interface não é evidência de aceleração ou boot PSP
em hardware real.

Os perfis declarativos de mailbox registram o protocolo lógico comprovado para
as famílias com boot pelo host: endereço em C2PMSG 36, comando em C2PMSG 35 e
sinal de vida do sOS em C2PMSG 81. SYS e SOS usam respectivamente `0x10000` e
`0x20000`; KDB e SPL só são aceitos nas famílias cujos callbacks upstream os
oferecem. Esses números ainda não são offsets MMIO: a tradução pelo mapa MP0
específico da geração continua obrigatória antes de qualquer escrita.

A base MP0 do IP discovery agora é obrigatória para o plano AMD. O kernel soma
essa base aos dwords oficiais `0x63`, `0x64` e `0x91`, converte o resultado para
offsets em bytes e rejeita overflow ou qualquer registrador que ultrapasse o
BAR de MMIO. A resolução é somente declarativa; nenhuma escrita PSP é feita.

Depois de mapear o BAR, o caminho AMD pode observar C2PMSG 35 e 81 e classificar
o PSP como bootloader ocupado, bootloader pronto, sOS ativo ou falha reportada.
Uma leitura `0xffffffff` é tratada como dispositivo/MMIO indisponível. Essa
sondagem é estritamente somente leitura e não inicia o handoff.

Existe agora um backend MMIO para a interface de transporte PSP, mas ele nasce
desarmado. O arming exige um snapshot `bootloader_ready`; a submissão revalida o
estado, escreve primeiro o endereço, aplica uma barreira de memória e só então
escreve o comando. Falha de leitura, status de erro ou comando divergente
desarma o transporte. Mapeamentos sem autorização apenas constroem a interface
e mantêm `psp-write-armed: 0`, sem habilitar qualquer escrita.
O arming também exige que o BAR tenha sido explicitamente marcado como
uncached; apenas o caminho de mapeamento MMIO validado pode abrir esse gate.

O mapeador x86-64 agora possui identity map uncached para MMIO. Quando o BAR já
está coberto por uma página enorme write-back, ele divide somente aquela página
de 2 MiB em folhas de 4 KiB, preserva os vizinhos e marca o intervalo solicitado
com PCD+PWT e NX. NVMe, xHCI, Ethernet e o BAR de registradores da GPU usam esse
caminho e verificam a política antes de acessar o dispositivo. Com essa garantia
o backend PSP pode ser marcado `uncached`, embora continue desarmado por padrão.
Como as folhas MMIO também são NX, o trampoline dos processadores secundários
habilita `EFER.NXE` junto com Long Mode antes de ativar paginação.

Escritas PSP exigem ainda uma autorização `psp-host-boot` na linha selecionada
de `csos-gpu.conf`. O marcador só é aceito para AMD com device, revisão e
subsystem IDs exatos e com os blocos `security` e `discovery` obrigatórios, por
exemplo:

```text
1002:744c:cc@1da2:e471=amdgpu/navi31/|security,graphics,dma,discovery,psp-host-boot
```

Mapeamentos genéricos, NVIDIA ou sem os blocos necessários são rejeitados. Sem
essa autorização o boot permanece somente leitura. Com ela, um mailbox pronto
pode armar e executar o handoff limitado descrito abaixo; portanto o marcador
só deve ser incluído para uma identidade Radeon deliberadamente habilitada.

Antes do arming, um preflight sem efeitos colaterais valida em conjunto a área
de transferência alinhada, a ordem SYS/SOS, todos os comandos exigidos pela
família, o estado inicial do mailbox e os gates de MMIO/autorização. O resultado
é exposto como `psp-preflight`; estados bloqueados continuam sem copiar payload
para a área de transferência e sem escrever registradores.

Quando o preflight retorna `ready`, o executor copia e submete uma imagem por
vez, espera a conclusão antes da próxima e usa tanto deadline do timer APIC como
limite de spins. Sucesso e falha desarmam o transporte; sOS já ativo encerra o
handoff sem submissão. O arquivo padrão usado no QEMU não autoriza host boot.
Se o primeiro snapshot autorizado encontrar o bootloader ocupado, o kernel faz
polling estritamente somente leitura, também limitado pelo timer APIC e por
spins, até observar `ready`, sOS ativo, erro ou timeout. O diagnóstico registra
essa passagem em `psp-mailbox-waited`.

O passo seguinte ao sOS não é TMR direto: o protocolo upstream submete TMR por
um ring PSP com buffers de comando e fence em endereços MC válidos. Como base
para isso, o plano GMC agora separa o BAR de registradores, o BAR 2 de doorbells
e o aperture opcional de VRAM no BAR 0, rejeita sobreposição e mapeia somente o
doorbell como MMIO uncached. `gtt-ready` permanece zero até page tables e
endereços MC serem realmente programados; memória física da CPU não é anunciada
como endereço de GPU.

Uma página de tabela GTT pode agora ser preparada com PTEs de sistema
`VALID|SYSTEM|SNOOPED|READABLE|WRITEABLE` para três páginas físicas separadas:
ring PSP, buffer de comando e fence. A tabela e os buffers nascem zerados e o
diagnóstico expõe `gtt-table`/`gtt-pages`, mas `active` continua falso e nenhum
endereço MC é derivado antes da programação específica do GMC.

O plano GART também preserva a diferença entre gerações observada no upstream:
GMC 9/10 exigem GFXHUB e MMHUB, enquanto o caminho GMC 11 inicializa somente o
MMHUB; GMC 12 volta a exigir ambos no plano atual. As bases dos hubs vêm do IP
discovery e uma ausência é terminal. A tabela inicial cobre uma janela mínima
de 2 MiB (512 páginas); `gart-active` permanece zero até os contextos VMID 0,
invalidação de TLB e leitura de confirmação específicos da família existirem.

As capacidades PSP são tratadas separadamente: `autoload_supported`, TMR de
boot e presença de callbacks host para carregar SYS/SOS não são sinônimos. O
handoff host só é construído para as famílias em que o `psp_funcs` upstream
expõe `bootloader_load_*`. PSP v10, v11.0.8 e v15 seguem o caminho já iniciado
pela plataforma e não são rejeitados por ausência de um pacote SOS combinado.

Os próximos incrementos de GPU devem privilegiar adaptação e reutilização do
AMDGPU/RADV e, depois, Nouveau/NVK compatíveis. O código Zig existente serve de
ponte de kernel, DRM e plataforma; ele não autoriza reimplementar integralmente
um driver Radeon ou NVIDIA moderno antes do primeiro frame Vulkan.

AMD Radeon e NVIDIA GeForce são requisitos oficiais. AMD é o primeiro backend
de referência; depois do primeiro triângulo RADV, o caminho NVIDIA deve ser
validado com NVK/stack compatível em hardware explicitamente suportado. M14 não
será considerada concluída com apenas um dos fabricantes.

O grande próximo desafio continua sendo a stack gráfica:

```text
AMDGPU/RADV e NVIDIA/NVK
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
