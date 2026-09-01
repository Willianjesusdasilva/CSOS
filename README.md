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

O alvo não é apenas detectar uma placa NVIDIA ou obter framebuffer. Suporte
NVIDIA significa inicialização, gerenciamento de memória, filas, sincronização
e um triângulo Vulkan em uma GeForce real suportada. Até essa validação existir,
o backend permanece experimental e não pode ser anunciado como funcional.

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

Estimativa de progresso em 2026-09-01: **aproximadamente 40% concluído e 60% a
fazer**. É uma estimativa ponderada por funcionalidade, não uma simples contagem
de milestones: M0–M13 possuem fundações implementadas, mas M14 ainda não tem o
dispatcher/ioctl de command submission nem triângulo Vulkan validado em AMD ou
NVIDIA, e M15–M30 continuam majoritariamente pendentes. O frame GFX11 de IB e
fence já é codificado e testado no host; isso não conta como validação de
hardware.

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

A ABI AMDGPU inicial também preserva por BO tamanho, alinhamento, domínio e
flags de criação, implementa `AMDGPU_GEM_METADATA` (set/get de até 256 bytes) e
`AMDGPU_GEM_WAIT_IDLE`. Este último só retorna idle porque o ioctl de command
submission ainda é recusado; `AMDGPU_INFO_ACCEL_WORKING` continua zero. A VM
possui isolamento por VMID e page tables testadas no host, e o ring gráfico já
passa o teste PM4 privado. O encoder de submissão produz o pacote GFX11
`INDIRECT_BUFFER` para VMIDs 1–7 seguido de `RELEASE_MEM` com fence de 64 bits.
`AMDGPU_CTX` já aloca, consulta e libera contextos de prioridade não privilegiada;
`AMDGPU_BO_LIST` cria, atualiza e destrói listas validadas, mantendo os BOs vivos.
O parser inicial de `AMDGPU_CS` aceita como formato somente um IB GFX simples e
prova contexto, lista, flags, limites e cobertura GPUVA legível página a página.
Ele ainda termina em `EOPNOTSUPP`: dispatcher e execução em Radeon real faltam,
portanto nenhum sequence number ou estado busy é inventado.
`AMDGPU_GEM_OP_GET_GEM_CREATE_INFO` devolve o descritor de criação original por
ponteiro de usuário validado, e `AMDGPU_GEM_LIST_HANDLES` enumera tamanho,
domínio, flags e alinhamento dos BOs ainda abertos. Placement em VRAM continua
recusado; somente BO page-backed no domínio GTT pode entrar no GPUVM atual.

O núcleo do GPUVM direto agora possui um allocator para VMIDs 1–7 (VMID0
permanece reservado ao sistema); VMIDs 8–15 ficam reservados ao MES conforme
o particionamento GMC11 upstream. Cada VM aceita até 32 intervalos. Map valida alinhamento de
4 KiB, limites do BO, flags R/W/X, overflow e o VA hole de 48 bits; overlap é
rejeitado dentro da VM, enquanto o mesmo VA pode existir isoladamente em outra
VM. Release remove todos os mappings antes de reciclar o VMID.
`AMDGPU_GEM_VA` aceita as estruturas UAPI atual (64 bytes) e legada (40 bytes)
para MAP/UNMAP imediato de páginas GTT. MAP é transacional entre todas as
páginas pedidas e aceita apenas R/W/X já codificados pelo GFX11; timeline,
delayed update, PRT, MTYPE e operações CLEAR/REPLACE retornam erro enquanto não
forem reais. UNMAP pré-valida o intervalo inteiro, e fechar um BO ainda mapeado
retorna busy. Sem o gate real, os context registers permanecem desabilitados.
O plano de vínculo para MMHUB 3.0/GMC11 exige o contexto previamente
desabilitado, escreve o PD address da raiz com
`VALID|SYSTEM|SNOOPED|BFS=9`, cobre o intervalo PFN de 48 bits, habilita
profundidade 3 e os faults-default, e invalida somente o VMID selecionado. Bind
e unbind possuem snapshot, readback e rollback inclusive quando o ACK de
invalidação expira. O ioctl não autoriza MMIO quando o GART não está ativo.
Depois que o gate explícito confirma PCI ID,
firmware, PSP, GART e ACK, o kernel publica ao DRM uma sessão de hardware. O
primeiro MAP faz bind da raiz; MAP/UNMAP posteriores invalidam apenas seu VMID;
o último UNMAP ou teardown faz unbind antes de liberar as páginas. Falha de
sincronização reverte as mudanças software e preserva o estado bound para nova
tentativa. Sem esse gate, `GEM_VA` continua somente como preparação lógica e
não toca MMIO. As páginas GPUVM e BOs page-backed também ficam abaixo da
máscara DMA coerente de 44 bits usada pelo GMC11. A execução desse lifecycle em
Radeon real ainda precisa ser validada.
O firmware gráfico GFX11 deixou de ser tratado apenas como uma contagem de
arquivos: a seleção agora distingue e exige PFP, ME, MEC, RLC, scheduler MES e
MES KIQ. As imagens MES têm seus offsets e tamanhos de código/dados validados
antes de qualquer preparação de execução. O primeiro contrato de ring segue o
upstream com 1024 dwords, MQD alinhado a página, EOP de 2048 bytes, ponteiros de
64 bits e doorbell obrigatório. O preflight permanece fechado enquanto
qualquer um desses recursos, PSP, GART ou GPUVM não estiver pronto; ele ainda
não programa o ring nem autoriza command submission.
PFP, ME, MEC e RLC também possuem agora seleção e parsing próprios para o
caminho pós-sOS. O formato legado separa a jump table MEC; o formato RS64
separa instruções e stacks e exige que PFP/ME/MEC usem o mesmo formato. O
staging físico produz payloads alinhados a 4 KiB com os tipos PSP oficiais,
incluindo duas stacks de PFP/ME, quatro de MEC e os componentes adicionais dos
cabeçalhos RLC 2.1–2.5. Alocação parcial é revertida e a máscara DMA de 44 bits
é obrigatória.
Como o protocolo PSP consome endereços GPU virtuais, esses payloads também são
agora mapeados no GART depois das filas, firmware e página de controle MES. O
bootstrap do ring KM/GPCOM para PSP 13.0.2 resolve C2PMSG 64/67/69/70/71 a
partir do `ip_discovery`, exige o sOS pronto e prepara endereço, tamanho e
comando de inicialização. O encoder `LOAD_IP_FW` reproduz o command buffer de
1024 bytes, o frame de 64 bytes, o fence e o wrap do WPTR em dwords.
O gate `-Damd-psp-ring=true` exige GART ativo, PCI ID exato e sOS confirmado;
ele cria o ring, submete todos os payloads em sequência e espera um fence por
comando. Falha de write/readback ou timeout destrói o ring e o bootstrap
restaura seus registradores. Respostas PSP não zero são contabilizadas como
warning, acompanhando o comportamento upstream para hardware físico. Sem o
gate não há escrita. O passo seguinte do fluxo PSP, `rlc_resume`, agora possui
um gate próprio (`-Damd-rlc-resume=true`). Ele constrói o Clear State Block
GFX11 oficial de 960 dwords em uma página física abaixo da máscara DMA,
mapeia essa página após os payloads CP/RLC e programa `RLC_CSIB_ADDR_HI/LO`,
`RLC_CSIB_LENGTH` e `RLC_SRM_CNTL`. Cada escrita tem readback; falha restaura
os quatro registradores. O gate exige GART ativo, PCI ID exato e todos os
payloads PSP carregados. MES também exige esse resume concluído. A transação
está testada no host, mas ainda não foi validada em Radeon real; `cp_resume`
e command submission continuam ausentes, portanto isso não constitui
aceleração 3D.
O caminho de `cp_resume` também deixou de reutilizar incorretamente as filas
MES: o ring gráfico 0 recebe uma página própria de 1024 dwords e outra para
RPTR/WPTR, ambas zeradas, transacionais e mapeadas no GART após o CSB. O layout
preserva o doorbell SOC21 `gfx_ring0=0x08B`, convertido para o índice 64-bit
`0x116` e offset `0x458`. O gate `-Damd-cp-gfx=true` só abre depois de GART,
PSP, RLC e recursos MES completos. Com ME/PFP previamente halted, ele programa
os ranges de doorbell, `CP_RB0`, contexto e device ID, libera ME/PFP, publica o
CSB de 960 dwords e exige RPTR=960. Em seguida, reproduz o teste obrigatório
do upstream: um pacote `SET_UCONFIG_REG` no mesmo ring deve alterar
`SCRATCH_REG0` de `0xCAFEDEAD` para `0xDEADBEEF` e avançar RPTR até 963. Falha
MMIO, doorbell ou timeout restaura os registradores ou desativa o ring e força
ME/PFP de volta a halt. O fluxo está host-tested, mas ainda requer validação
Radeon; ele não expõe command submission à ABI.
As duas filas exigidas pelo bootstrap — scheduler MES ring0 e KIQ ring1 — agora
recebem, cada uma, páginas físicas separadas para ring, MQD, EOP e ponteiros.
As oito páginas nascem zeradas abaixo da máscara DMA de 44 bits e são liberadas
em ordem reversa se qualquer alocação ou limpeza falhar. O GART reserva oito
entradas após as três páginas PSP e fornece endereços MC distintos às filas.
Os MQDs de 512 dwords codificam bases, EOP, RPTR/WPTR e os doorbells reservados
`0x0b/0x0c` conforme SOC21, mas preservam `HQD_ACTIVE=0`. O preflight pode
confirmar que os recursos estão completos sem ativar fila, tocar o doorbell ou
autorizar command submission.
A seleção MES agora segue a preferência upstream de GFX11: `mes_2` para o
scheduler, com fallback explícito para `mes`, e `mes1` separado para a KIQ.
Cada cabeçalho fornece versões, endereços de início e fatias independentes de
código/dados; valores vazios, offsets fora da imagem e IP diferente de 11 são
rejeitados. Os quatro payloads são copiados para alocações físicas
transacionais e recebem entradas GART a partir da página 11, respeitando o
limite total de 512 entradas. Isso ainda é staging: nenhum microcontrolador MES
é iniciado por esse passo.
O resolvedor GFX11 também localiza o bloco de registradores MES pela base GC
correta do `ip_discovery`. Uma leitura de `CP_MES_CNTL` só considera a unidade
seguramente parada quando os dois pipes estão em reset, ambos inativos e
`MES_HALT` está ligado. Apenas nesse estado são construídos write-sets para
selecionar ME3/pipe0 ou ME3/pipe1 e programar PC, bases e limites de instrução e
dados. Os planos sempre restauram o seletor GRBM e não são executados: não há
unhalt nem ativação escondida neste checkpoint.
Uma transação de carga por pipe agora captura todos os registradores após
selecionar o pipe, aplica cada write com readback e restaura o snapshot em
ordem reversa diante de falha. O segundo pipe só é carregado depois do primeiro;
se ele falhar, o primeiro também é restaurado. Escritas reais exigem
simultaneamente `-Damd-gart-mmio=true`, `-Damd-mes-mmio=true` e o PCI ID exato
em `-Damd-gart-device=0xNNNN`, além de GART ativo e nova confirmação de que MES
continua halted. Mesmo com esse gate, a transação apenas carrega bases/PC:
unhalt, ativação dos pipes e doorbells permanecem proibidos.
O unhalt dos dois pipes ganhou uma transação separada e opt-in por
`-Damd-mes-activate=true`, que só é aceita junto dos gates de carga MES, GART e
PCI ID. A transação reprograva os PCs com MES ainda halted, libera pipe0/pipe1
simultaneamente e consulta `CP_MES_GP3_LO` sob seleção ME3 para cada pipe. Só
considera o handshake concluído quando scheduler e KIQ publicam versões não
zero. Timeout ou readback incoerente restaura imediatamente reset+halt e o
seletor GRBM neutro. Esse handshake prova vida dos microcontroladores, mas não
inicializa HQD, não toca doorbell e ainda não habilita command submission.
A KIQ possui agora um gate posterior, `-Damd-mes-kiq=true`. O plano deriva do
MQD validado e seleciona exclusivamente `ME3/pipe1/queue0`: força HQD inativo,
desabilita o doorbell, programa VMID0, bases MQD/ring, RPTR/WPTR, controle e
estado persistente, reabilita o doorbell e grava `HQD_ACTIVE=1` por último.
Quatorze registradores distintos são capturados antes das escritas; cada valor
tem readback e qualquer falha restaura tudo em ordem reversa. Se a ativação da
KIQ falhar, os dois pipes MES também retornam a reset+halt. Este estágio ainda
não considera o scheduler pronto.
Um gate ainda mais restrito, `-Damd-mes-kiq-test=true`, envia somente o teste
privado de ring usado pelo upstream GFX11: cinco dwords `WRITE_DATA` escrevem
`0xDEADBEEF` em `SCRATCH_REG0`. O kernel zera ring/RPTR, publica WPTR=5 com
ordenação atômica, toca apenas o doorbell 64-bit da KIQ e espera a scratch com
timeout. A abertura do doorbell valida aperture e offset exatos. Falha de
escrita ou timeout restaura a transação HQD e força MES para reset+halt. O
teste está coberto no host, mas ainda precisa ser executado em Radeon real;
ele não expõe command submission à ABI e não torna aceleração disponível.
Depois desse fence, `-Damd-mes-scheduler-map=true` pode emitir pela mesma KIQ
o `MAP_QUEUES` de sete dwords usado pelo upstream para a fila MES scheduler
(`ME2/pipe0/queue0`, engine 5). O MQD alvo precisa continuar com
`HQD_ACTIVE=0`, e o ring KIQ precisa estar comprovadamente ocioso em
RPTR=WPTR=5. O pacote é seguido por outro teste de scratch; somente scratch
confirmada e RPTR=WPTR=17 contam como sucesso. Timeout restaura a HQD KIQ e
leva MES a reset+halt. `SET_RESOURCES` não é usado aqui porque pertence ao
caminho KCQ legado, não ao bootstrap da fila MES scheduler.
O próximo frame do scheduler, `SET_HW_RSRC`, também já possui preparação
fail-closed, mas ainda não é emitido. Uma página física zerada é mapeada no
primeiro slot GART após o firmware e separa contexto do scheduler, query fence,
completion fence da API e fence final. O encoder reproduz o frame upstream de
64 dwords, preserva as três listas de bases IP e recusa VMID0 nas máscaras ou
um conjunto HQD vazio. O plano agora deriva do `ip_discovery` as bases
GC/MMHUB/OSSSYS, valida GFX11/MMHUB3/SDMA6 e aplica a geometria upstream:
VMIDs `8–15`, duas GFX pipes com máscara `0x2`, quatro compute pipes com
`0xC`, SDMA presente com `0xFC` e doorbells agregados `0x800..0x808` dentro
do aperture. Um último gate, `-Damd-mes-scheduler-init=true`, constrói no ring
scheduler dois frames consecutivos de 64 dwords: `SET_HW_RSRC` e
`QUERY_SCHEDULER_STATUS`. Ele publica WPTR=128 no doorbell ring0 e só conclui
quando o completion fence da primeira API, o fence da query e RPTR=128 forem
observados. O timeout de 2,1 milhões de polls restaura a HQD KIQ e força MES a
reset+halt. O caminho está host-tested e compila com toda a cadeia de gates,
mas ainda requer Radeon real; ele não expõe command submission ao userspace.
Para revisões MES `scheduler_version & 0xFFF >= 0x52`, o gate adicional
`-Damd-mes-scheduler-resource1=true` executa o `SET_HW_RSRC_1` obrigatório.
A página de controle reserva um cleaner-shader fence próprio; o frame habilita
o contexto informativo sem inventar endereço SR-IOV e é seguido por outra
`QUERY_SCHEDULER_STATUS`, agora com fence de sequência 2. O ring progride de
WPTR/RPTR 128 para 256. Revisões anteriores ignoram corretamente esse estágio;
timeout em revisão nova restaura KIQ e retorna MES a reset+halt. A validação em
Radeon real permanece pendente.
Para VA de 48 bits, o walker segue `PDB2[47:39] → PDB1[38:30] →
PDB0[29:21] → PTB[20:12]`, com offset `[11:0]`. Cada nível possui até 512
entradas de 64 bits e ocupa uma página de 4 KiB, conforme a geometria do
AMDGPU VMPT upstream. O código já rejeita VA fora dos 48 bits; PDEs só serão
emitidos depois que as quatro páginas físicas/VRAM do caminho forem alocadas.
Um allocator transacional agora materializa essas quatro páginas, exige
alinhamento de 4 KiB, rejeita endereço zero/duplicado, limpa cada página e
libera em ordem reversa. Falha em qualquer nível devolve todos os níveis já
alocados. O backend físico usa o allocator do kernel; o teste host injeta falha
no terceiro nível e comprova ausência de leak.
O lifecycle do VMID agora exige `allocate → materialize → map/unmap →
dematerialize → release`: não é possível liberar VMID com tabelas vivas nem
desmaterializar enquanto houver intervalos GPUVA ativos.
O primeiro page path pode agora ser ligado: PDB2→PDB1 usa BFS=9,
PDB1→PDB0 usa `TRANSLATE_FURTHER`, PDB0→PTB usa PDE base e a PTE final converte
R/W/X da UAPI nos bits GFX11. Todos os níveis em RAM carregam
VALID|SYSTEM|SNOOPED; endereços fora da máscara física, desalinhamento e
colisão com entrada diferente são rejeitados antes de alterar a hierarquia.
`mapSystemPage` coordena o intervalo lógico e a PTE como uma única operação:
se path/PTE falhar, remove o mapping recém-criado. `unmapSystemPage` confirma
flags e PTE esperada, zera a folha e só então remove o intervalo; uma PTE de
outro BO nunca é apagada por engano.
O planejamento dinâmico de branches agora compartilha PDB1/PDB0/PTB quando os
índices superiores coincidem, mantém referências por página mapeada e poda
PTB, PDB0 e PDB1 vazios durante unmap. A capacidade atual é explicitamente
limitada a 32 PDB1, 64 PDB0 e 128 PTB por planejador, com erro em vez de
sobrescrita ao esgotar. O manager agora materializa somente a raiz PDB2 e
aloca as páginas PDB1, PDB0 e PTB sob demanda. Antes de publicar qualquer PDE,
valida todos os links e a PTE; falha de alocação libera em ordem reversa as
páginas novas e também desfaz o intervalo lógico. No último unmap de um nó, os
links pais são zerados e as páginas vazias são devolvidas ao allocator. Testes
host atravessam dois ramos PDB2, comprovam compartilhamento dentro do mesmo PTB
e injetam falha durante a expansão sem deixar página ou mapping residual.

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

Para GMC 11, o mapa MMHUB v3.0 agora resolve os registradores oficiais de
`CONTEXT0_CNTL`, base/início/fim da page table, controles L1/L2 e invalidate
engine 17 request/ack. Os índices em dwords são somados à base MMHUB descoberta,
convertidos para offsets em bytes e rejeitados se excederem o BAR. A existência
de `gart-registers` comprova somente o mapa; não ativa o contexto.

O plano também distingue explicitamente o endereço físico da tabela na CPU do
endereço MC que o MMHUB consumirá. O binding exige endereços alinhados a 4 KiB,
uma janela sem overflow dentro dos 48 bits representáveis pelos registradores
GMC 11 e rejeita rebinding. Enquanto nenhum mecanismo de VRAM/GTT fornecer um
endereço MC comprovado, `gart-bound` e `gart-table-mc` permanecem zero; o kernel
não reutiliza silenciosamente o endereço físico da CPU.

A topologia GMC 11 passa a observar, sem escrita, os registradores MMHUB v3.0
`MMMC_VM_FB_LOCATION_BASE` e `MMMC_VM_FB_OFFSET`. Os campos são convertidos das
unidades oficiais de 16 MiB para `vram-mc-base` e `vram-mc-offset`; leituras
`0xffffffff` são rejeitadas como MMIO indisponível. O tamanho da VRAM continua
dependendo da descoberta NBIO e não é deduzido do tamanho do BAR 0, que representa
somente a janela visível pela CPU. As versões NBIO 7.7, 7.9, 7.11 e NBIF 6.3.1
usadas pelo dispatcher upstream resolvem `CONFIG_MEMSIZE` pelo terceiro base
segment do IP discovery e convertem o valor em MiB para `vram-bytes`. Versão,
base ausente, tamanho zero e MMIO indisponível são terminais. Mesmo com esse
snapshot, o binding aguarda reservar uma tabela dentro de VRAM visível.

A janela visível agora preserva a tradução usada pelo TTM upstream: offset zero
do BAR 0 corresponde ao início MC da VRAM e `visible = min(BAR, VRAM real)`.
O framebuffer entregue pelo firmware precisa caber integralmente nessa janela;
se couber, sua faixa CPU é convertida e registrada como `framebuffer-mc`, nunca
tratada como espaço livre. Isso ainda não escolhe uma página para a tabela: o
AMDGPU original faz essa reserva por BO/TTM antes de copiar e piná-la.

O allocator bootstrap de VRAM agora modela essa disciplina: inicia com o
framebuffer reservado, normaliza intervalos de firmware sobrepostos/adjacentes e
recusa qualquer alocação enquanto o mapa não estiver explicitamente selado.
Depois do selo, aloca de cima para baixo com alinhamento power-of-two, registra
cada faixa como pinned e devolve os endereços CPU e MC correspondentes. O boot
ainda não sela o mapa, pois as demais reservas PSP/VBIOS não foram enumeradas;
portanto nenhuma page table é copiada para VRAM nesta etapa.

O mapa de boot GMC 11 também normaliza como ocupado todo o prefixo da VRAM até
o fim do framebuffer pré-OS, seguindo a reserva VGA/scanout do upstream. Quando
IP discovery usa TMR, os últimos 64 KiB da VRAM real também são reservados se
caírem na janela CPU-visível; caudas fora do BAR já são inalocáveis por este
allocator. O selo continua fechado até conhecer a reserva firmware completa.

Como pré-requisito para importar `vram_usagebyfirmware`, a descoberta PCI sonda
também o Expansion ROM BAR de dispositivos display header type 0. O kernel mapeia
essa janela sem cache, habilita o decode somente durante uma cópia para RAM e
restaura tanto o command register quanto o ROM BAR antes de interpretar qualquer
byte. O boot confirma a restauração e libera o buffer temporário imediatamente;
em QEMU, `rom-read: 1` e `rom-restored: 1` validam esse ciclo sem executar a ROM.

O parser ATOM puro valida a assinatura PCI, o tamanho declarado da imagem, todos
os limites dos headers ROM/master/data e decodifica
`vram_usagebyfirmware` 2.1 e 2.2+. Por enquanto esses campos são apenas
diagnóstico (`atom-fw-kib`/`atom-driver-kib`): a semântica upstream reserva as
faixas estáticas sobretudo para SR-IOV, então o allocator bare-metal não deve
tratar esses números indiscriminadamente como VRAM ocupada.

O mesmo parser extrai `firmwareinfo` 3.4/3.5 e usa
`fw_reserved_size_in_kb` para a cauda bare-metal do TMR; se o campo não existir
ou for zero, aplica o fallback upstream de 64 KiB. Quando a capability de
treinamento em dois estágios está presente, também reserva o bloco GDDR6 de
4 KiB na posição alinhada usada pelo AMDGPU. Com scanout, TMR e treinamento
enumerados, o mapa firmware é selado. A page table GART de 4 KiB então recebe
uma alocação pinned na VRAM visível, é copiada pela janela CPU sem cache e o
plano passa a carregar endereços CPU/MC distintos e a janela virtual alta. Isso
ainda não ativa o GART nem escreve os registradores MMHUB.

O mapa MMHUB v3.0 foi ampliado para toda a sequência de ativação usada pelo
upstream: aperture AGP/sistema, páginas default e de fault, controles L1/L2,
identity aperture, VMID 0–15 e ranges dos 18 engines de invalidação. O conjunto
de 141 registradores mutáveis é enumerado sem duplicatas para formar o snapshot
de rollback da futura transação. Os seis valores do aperture GART também são
pré-calculados, incluindo o bit `AMDGPU_PTE_VALID` no endereço raiz e as unidades
de página exigidas pelos registradores. O boot expõe
`gart-aperture-ready`/`gart-rollback-registers`, mas mantém `gart-active: 0`.

O system aperture agora também possui seus recursos reais: uma scratch page
pinned de 4 KiB na VRAM visível e uma dummy page de 4 KiB na memória física.
A tradução do endereço MC da scratch segue `mc - vram_start +
vram_base_offset`; ambas são zeradas antes do uso e rejeitadas fora dos 48 bits
aceitos pelo hardware. Falhas durante a preparação liberam a página física e a
alocação VRAM pode ser removida do allocator selado sem afetar reservas de
firmware. Os valores AGP desabilitado, limites da VRAM e endereços default/fault
em unidades de página são pré-calculados em `gart-system-aperture-ready`, ainda
sem qualquer escrita MMIO.

A infraestrutura de transação do MMHUB captura os 141 registradores antes da
primeira escrita, restringe cada operação a um offset incluído no snapshot e
confirma o valor por readback com máscara. Em falha de escrita ou leitura, tenta
restaurar todos os registradores em ordem reversa e depois verifica cada valor;
uma falha persistente de rollback é reportada separadamente. O self-test de boot
exercita sucesso, restauração explícita, falha transitória com rollback automático,
falha persistente no meio do conjunto e falha de captura. O transporte usado no
teste é inteiramente em memória; o transporte MMIO real permanece desarmado.

O write-set de bootstrap contém 80 operações ordenadas. Ele programa a page
table e a janela GART, system aperture, páginas default/fault, TLB L1, cache L2,
VMID0, fechamento da identity aperture e os 18 ranges de invalidação. Campos
RMW são calculados a partir do snapshot. Os VMIDs 1–15 são explicitamente
mantidos desabilitados até existir o gerenciador de page directories de
processos; registradores com bits de invalidação auto-limpáveis usam máscara de
readback apropriada. O self-test aplica e restaura o write-set inteiro sem MMIO.
Depois da programação, o handshake de invalidação usa o engine 0 e VMID0:
publica `0x00f80001` (PTE, PDE0/1/2 e L1), espera o bit de ACK com limite de
polls e retorna timeout explícito. O banco sintético cobre ACK tardio e timeout;
o snapshot integral continua sendo a origem do rollback antes de qualquer
ativação real. A ativação é atômica: aplica as 80 escritas, exige o ACK e, se o
handshake falhar, restaura todos os registradores mutáveis em ordem reversa e
zera o estado da transação. `zig build test` executa esse caminho no host sem
depender da stack reduzida da entrada UEFI.

O transporte MMIO GMC 11 agora é um gate separado do planejamento: ele só lê
ou escreve quando a BAR de registradores é não-prefetchable, está mapeada como
uncached, o dispositivo é AMD `0x1002`, a autorização foi concedida e `arm()`
foi chamado explicitamente. A autorização exige que todos os firmwares
selecionados tenham sido validados, que exista firmware de segurança, IP
discovery GMC 11 compatível, tabela e janela GART vinculadas e os 141
registradores de rollback enumerados. A autorização ocorre somente depois de
PSP `sos_alive` ou do handoff host terminar, seguindo a dependência de segurança
e TMR da sequência AMDGPU. Em Radeon elegível o boot concede essa
autorização, mas mantém `gart-write-armed=0`; o teste nativo prova que firmware
parcial, acessos antes de armar e tentativas sem autorização são rejeitados.

Snapshot, conjunto de escritas e estado da transação vivem agora em um
`AmdGmc11ActivationWorkspace` persistente, fora da stack de boot. A API separa
`prepare`, `commit` e `rollback`: prepare captura os 141 registradores e monta
as 80 escritas; commit só marca ativo depois do ACK; rollback restaura o
snapshot. Timeout limpa `prepared/active` e não deixa uma transação fantasma.
O workspace real nasce com `gart-activation-prepared=0` e
`gart-activation-committed=0` até o gate de hardware real ser explicitamente
armado.

A execução real permanece opt-in e presa ao modelo exato. É necessário fornecer
`-Damd-gart-mmio=true -Damd-gart-device=0xNNNN`; ID ausente ou diferente do PCI
detectado causa panic antes de `arm()`. Só após todos os gates o caminho faz
`arm → prepare → commit → disarm`; o plano só
recebe `gart-active=1` depois do ACK. Falha de preparação desarma sem escrever;
falha/timeout no commit restaura o snapshot antes do panic. Sem a opção (padrão),
o caminho é compilado e testado, mas nenhuma escrita GMC é realizada.
Um teste real também registra `gart-snapshot-digest`, `gart-write-digest` e
`gart-invalidate-polls`; os digests FNV-1a permitem comparar exatamente o
estado capturado e a transação entre boots sem despejar conteúdo sensível ou
centenas de registradores na serial.

Com a faixa real conhecida, o candidato `gart-window-start/end` segue a política
`AMDGPU_GART_PLACEMENT_HIGH`: limita o espaço MC antes do VA hole de 48 bits,
posiciona a janela no topo e alinha sua base a 4 GiB. Overflow, faixa VRAM
inválida e sobreposição são rejeitados. Esse candidato ainda não define
`gart-bound`, pois o endereço MC da própria page table continua ausente.

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

O suporte será registrado por fabricante, família de GPU e caminho Vulkan.
Detecção PCI ou display básico não bastam: cada entrada só pode ser marcada
como funcional depois de inicialização, memória, filas, sincronização e um
triângulo Vulkan passarem em hardware real. Até lá, AMD e NVIDIA permanecem
como trabalho de M14, e Steam/CS2 continuam bloqueados atrás das milestones do
sistema operacional.

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
