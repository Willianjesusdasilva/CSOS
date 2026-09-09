# CSOS — objetivo, prioridades e ordem de execução

## Objetivo

Construir um sistema operacional x86-64 escrito principalmente em Zig, funcional em hardware real e otimizado para executar Steam e Counter-Strike 2 com:

```text
baixo overhead
frametime consistente
baixa latência de input
bons 1% lows e 0.1% lows
mínima interferência do sistema durante partidas
```

O sistema operacional vem primeiro.

Steam Runtime, Steam e Counter-Strike 2 permanecem deliberadamente nas últimas etapas.

Eles não devem antecipar nem bloquear:

```text
boot
memória
processos
filesystem
armazenamento
input
rede
áudio
display
interface
WebKit
instalação
recuperação
Git
SSH
Nix
GPU/Vulkan
estabilidade
```

---

# Regra principal

Priorizar sempre:

```text
funciona > simples > rápido > bonito
```

Não criar complexidade sem necessidade real.

Não transformar o CSOS em uma distribuição Linux genérica.

Não perseguir features periféricas enquanto existir um bloqueio direto no caminho atual.

---

# Filosofia operacional

A arquitetura do projeto passa a seguir:

```text
CSOS   = laboratório
Alpine = paraquedas
Nix    = caixa de ferramentas
Git    = fonte da verdade
```

O CSOS é experimental por design.

Pode quebrar.

Commits de desenvolvimento podem impedir o boot.

Isso é aceitável desde que a máquina possa ser recuperada de maneira simples e previsível.

Não tentar transformar o CSOS neste estágio em um sistema imutável, transacional ou impossível de quebrar.

---

# Regra anti-desvio

Antes de iniciar qualquer tarefa, responder:

> Esta tarefa resolve o bloqueio atual ou é necessária para o próximo gate verificável?

Se a resposta for não, não executar agora.

Não trocar de frente apenas porque apareceu uma tarefa pequena e fácil.

Não fazer dezenas de commits periféricos para evitar o bloqueio principal.

Um commit pequeno é aceitável quando está diretamente no caminho crítico.

Exemplo correto:

```text
WebKit pede Cairo
↓
portar Cairo
↓
CMake avança
```

Exemplo incorreto:

```text
WebKit pede Cairo
↓
refatorar launcher
↓
melhorar ícone
↓
adicionar comando cosmético
↓
reescrever documentação não relacionada
```

---

# Estado de prioridade excepcional

A partir desta revisão do GOAL existe uma **fase excepcional curta** que temporariamente antecede a prioridade anterior.

Ela existe para tornar possível desenvolver o CSOS continuamente em notebook/hardware real sem depender de reinstalações manuais.

A ordem imediata passa a ser:

```text
P0  separar sistema e estado persistente
 ↓
P1  Git como mecanismo oficial do CSOS
 ↓
P2  instalação bare-metal + Alpine Recovery
 ↓
P3  rede + SSH para desenvolvimento/recuperação
 ↓
P4  Nix mínimo funcional
 ↓
RETORNAR À PRIORIDADE ANTERIOR
 ↓
WPE WebKit
 ↓
UI completa
 ↓
restante do roadmap original
```

Essa fase não redefine o objetivo do projeto.

É infraestrutura para acelerar o restante do desenvolvimento.

---

# IMPORTANTE — não ficar preso nesta nova fase

Git, Alpine, SSH e Nix devem atingir o **mínimo funcional necessário**.

Depois disso:

> parar de expandir essa infraestrutura e retornar imediatamente ao WebKit e ao roadmap anterior.

Não transformar esta fase em:

```text
novo package manager
gerenciador gráfico de pacotes
sistema A/B
updater proprietário
orquestrador de versões
sistema de snapshots complexo
recovery gráfico
desktop Alpine
gerenciamento enterprise
```

Nada disso é necessário agora.

---

# P0 — Separação entre sistema e estado

## Objetivo

Permitir que o checkout Git do CSOS seja destruído, restaurado ou substituído sem apagar dados específicos daquela instalação.

Modelo:

```text
/system
│
└── conteúdo reproduzível/versionado

/data
│
└── estado específico da máquina

/home
│
└── dados do usuário

/nix
│
└── store e profiles Nix
```

Configurações padrão:

```text
/system/config/defaults/
```

são versionadas.

Configuração gerada para a máquina:

```text
/data/config/hardware.csc
```

não é versionada.

Substituir referências antigas a:

```text
/system/config/hardware.csc
```

pela nova separação apropriada.

## Gate P0

P0 termina quando:

* [ ] defaults versionados estão separados do estado local;
* [ ] `hardware.csc` específico da máquina fica fora da árvore que receberá reset Git;
* [ ] `/home` fica fora do checkout;
* [ ] `/data` fica fora do checkout;
* [ ] `/nix` fica fora do checkout;
* [ ] logs persistentes não impedem reset do sistema;
* [ ] `git reset --hard` conceitualmente pode destruir o checkout sem destruir estado do usuário.

Não expandir P0 além disso.

---

# P1 — Git como mecanismo oficial de atualização

## Objetivo

O próprio sistema operacional deve estar exposto através de Git.

Não criar um updater proprietário como interface principal.

O modelo desejado é:

```bash
cd /system
git status
git pull
reboot
```

Também deve ser possível:

```bash
git log
git diff
git show
git fetch
git switch <branch>
git checkout <commit>
git reset --hard origin/main
```

O commit deve representar uma versão identificável do CSOS.

## Fonte da verdade

Deve ser reproduzível a partir do Git:

```text
kernel
drivers
userspace específico
UI
scripts
config defaults
build definitions
integrações necessárias
```

Build artifacts locais não devem ser considerados fonte da verdade quando podem ser reproduzidos.

Artefatos ignorados em:

```text
.tools
zig-out
```

não contam como integração reproduzível por si só.

Dependências externas podem ser baixadas/construídas, mas versões, scripts e parâmetros necessários para reproduzi-las devem ser versionados.

## Dirty tree

Não apagar silenciosamente modificações locais.

Se o usuário executar:

```bash
git pull
```

com alterações incompatíveis, Git deve apresentar seu comportamento normal.

Não inventar auto-reset destrutivo.

O usuário pode deliberadamente usar:

```bash
git reset --hard
```

quando quiser.

## Gate P1

P1 termina quando existir um caminho real ou suficientemente completo para:

```text
CSOS instalado
↓
Git disponível
↓
git pull
↓
nova revisão presente
↓
reboot
↓
nova revisão utilizada
```

e a revisão instalada puder ser identificada.

Não implementar A/B agora.

Não implementar updater próprio agora.

---

# P2 — Bare-metal e Alpine Recovery

## Objetivo

Permitir que o CSOS seja instalado em uma máquina de desenvolvimento e que um segundo sistema independente consiga reparar o CSOS quando ele quebrar.

Layout conceitual:

```text
NVMe
│
├── EFI
├── CSOS
├── Alpine Recovery
├── /data
├── /home
└── /nix
```

Não é obrigatório que cada item represente literalmente uma partição independente se outra organização simples cumprir os mesmos requisitos.

A implementação deve favorecer simplicidade.

---

# Alpine Recovery

Utilizar Alpine Linux como sistema de recuperação externo.

Alpine não faz parte do runtime normal do CSOS.

Quando CSOS está executando:

```text
Alpine não está executando
```

portanto não existe impacto de runtime no jogo.

O Recovery deve ser terminal-only.

Não criar interface gráfica para ele.

Ferramentas mínimas desejadas:

```text
shell
Git
SSH
rede
DNS
mount
filesystem tools
NVMe/storage tools
curl ou wget
```

---

# Fluxo obrigatório de recuperação

Deve ser possível realizar:

```text
CSOS funcionando
↓
instalar commit quebrado
↓
reboot
↓
CSOS não inicia
↓
selecionar Alpine Recovery no boot
↓
montar filesystem do CSOS
↓
entrar no checkout
↓
Git
↓
restaurar/atualizar
↓
reboot
↓
CSOS volta
```

Exemplo esperado:

```bash
mount <partição-CSOS> /mnt/csos

cd /mnt/csos

git status
git fetch
git reset --hard origin/main

reboot
```

Também deve ser possível receber uma correção nova:

```bash
git pull
```

---

# Bootloader

O Recovery deve continuar inicializável mesmo se o CSOS estiver completamente quebrado.

Falhas em:

```text
kernel CSOS
userspace CSOS
WebKit
UI
drivers
filesystem lógico do sistema
configuração do CSOS
```

não devem impedir a seleção do Recovery quando a partição necessária estiver íntegra.

Boot padrão:

```text
CSOS
```

Opção secundária:

```text
CSOS Recovery
```

---

# Gate P2

P2 termina quando houver evidência funcional de:

* [ ] instalação do CSOS em armazenamento;
* [ ] boot do CSOS a partir desse armazenamento;
* [ ] Alpine Recovery independente;
* [ ] menu ou método simples para selecionar Recovery;
* [ ] montagem do filesystem CSOS pelo Alpine;
* [ ] acesso ao checkout Git pelo Recovery;
* [ ] restauração de uma versão pelo Git;
* [ ] reboot de volta para o CSOS.

Não continuar refinando o instalador depois do gate mínimo se isso não bloquear o restante.

---

# P3 — Rede e SSH

## Objetivo

Transformar hardware real em um alvo de desenvolvimento remoto.

A prioridade inicial é:

```text
Ethernet
↓
IP
↓
DNS
↓
SSH
```

Wi-Fi pode vir depois se não for necessário para o primeiro notebook alvo.

Não atrasar SSH esperando suporte genérico a todo hardware de rede.

---

# SSH no CSOS

Objetivo:

```text
PC de desenvolvimento
        ↓
       SSH
        ↓
      CSOS
```

Isso deve permitir, conforme as ferramentas disponíveis:

```text
comandos
logs
Git
testes
diagnósticos
reboot
```

Dropbear pode ser utilizado inicialmente se for significativamente mais simples que OpenSSH.

Não implementar servidor SSH próprio.

---

# SSH no Alpine

O Recovery também deve poder oferecer SSH.

Fluxo:

```text
CSOS quebra
↓
boot Alpine
↓
rede
↓
SSH
↓
desenvolvedor/agente acessa
↓
monta CSOS
↓
Git
↓
corrige
```

## Gate P3

P3 termina quando ao menos um caminho real suportado permitir:

```text
boot
↓
rede
↓
SSH
↓
comando remoto
```

no CSOS ou, para recuperação, no Alpine.

O objetivo ideal é ambos.

Não transformar SSH em uma grande frente de infraestrutura.

---

# P4 — Nix

## Objetivo

Validar Nix como camada preferencial para aplicações e dependências adicionais.

Responsabilidades:

```text
Git    → CSOS
Nix    → apps e dependências
Alpine → recovery
```

Nix não atualiza o kernel CSOS.

Nix não substitui o checkout do sistema.

Nix não é razão para criar um package manager próprio.

---

# Persistência Nix

Utilizar:

```text
/nix
```

fora da árvore Git.

O conteúdo deve sobreviver a:

```text
git reset --hard
reboot
atualização do CSOS
```

---

# Compatibilidade

Não implementar dezenas de syscalls antecipadamente apenas porque Nix talvez precise delas.

Executar Nix.

Observar o próximo erro real.

Implementar o requisito correto.

Repetir.

Fluxo:

```text
executar Nix
↓
erro concreto
↓
identificar contrato Linux ausente
↓
implementar corretamente
↓
teste
↓
próximo gate
```

A mesma regra usada para WebKit deve ser aplicada.

---

# Gate mínimo do Nix

Nix só será considerado minimamente funcional quando, dentro do CSOS:

```bash
nix profile install nixpkgs#hello
hello
```

funcionar.

Depois validar:

```bash
nix profile install nixpkgs#curl
curl https://example.com
```

Isso implica validar o necessário de:

```text
exec
processos
filesystem
/proc
/sys
/dev
pipes
permissões
mmap
futex
rede
DNS
TLS
certificados
```

Após reboot, `/nix/store` e profiles devem permanecer válidos.

## Gate P4

* [ ] Nix executa no CSOS.
* [ ] `/nix` é persistente.
* [ ] `hello` pode ser instalado e executado.
* [ ] `curl` pode ser instalado.
* [ ] requisição HTTPS real funciona.
* [ ] reboot preserva store/profile.

Quando esses itens funcionarem:

> P4 está concluída.

Não continuar tentando fazer centenas de pacotes funcionarem.

Não tentar Steam via Nix nesta fase.

**RETORNAR IMEDIATAMENTE AO ROADMAP ANTERIOR.**

---

# Fim da prioridade excepcional

Quando P0–P4 estiverem funcionalmente concluídas:

```text
Git funcionando
+
estado separado
+
Alpine recuperando
+
SSH utilizável
+
Nix mínimo funcionando
```

a prioridade especial termina.

A próxima tarefa NÃO é melhorar Alpine.

A próxima tarefa NÃO é melhorar Nix.

A próxima tarefa NÃO é criar updater.

A próxima tarefa NÃO é criar package manager.

A prioridade volta automaticamente para:

```text
WPE WEBKIT
```

no ponto exato em que seu port estiver.

---

# PRIORIDADE APÓS P0–P4

A ordem volta a ser:

```text
1. concluir port WPE WebKit no CSOS
2. desktop HTML/CSS/JavaScript real
3. integrar WebKit ao compositor/input/backend CSOS
4. concluir SDL/áudio/UI necessários
5. continuar Linux ABI conforme requisitos reais
6. hardware discovery/autotune completo
7. GPU/Vulkan física AMD e NVIDIA quando houver hardware dedicado
8. otimizações GAME/MATCH medidas
9. Steam Runtime
10. Steam
11. Counter-Strike 2
12. integração e performance final
```

---

# WebKit — prioridade principal após a fase excepcional

Todo o desktop solicitado deve executar:

```text
HTML
CSS
JavaScript
```

por WebKit em userspace.

A base escolhida é WPE WebKit.

O WebKit existente deve ser reutilizado, não reescrito.

Kernel e backend específico do CSOS continuam prioritariamente Zig.

---

# Critério de WebKit

Não declarar WebKit integrado por:

```text
abrir HTML
parser próprio
preview
framebuffer
mailbox
pixel
teste no Windows
teste no Linux host
```

A aceitação exige WebKit rodando dentro do CSOS.

Gate mínimo:

```text
WPE WebKit no CSOS
↓
HTML renderizado
↓
CSS aplicado
↓
JavaScript executado
↓
JS altera DOM
↓
input real chega ao WebKit
↓
ação chega ao backend CSOS
```

Até isso acontecer, o runtime HTML próprio é somente:

```text
bootstrap / fallback
```

Não é a entrega final.

---

# Regra do critical path do WebKit

Durante o port:

```text
CMake/WebKit aponta dependência ausente
↓
resolver essa dependência
↓
reexecutar configuração
↓
observar próximo gate
```

Não desviar para features periféricas.

Dependências target devem ser reproduzíveis.

Ferramentas host necessárias ao build devem ser separadas corretamente das dependências target.

`.tools` e `zig-out` locais não contam como integração se os scripts/versionamento necessários não conseguirem reconstruí-los.

---

# Marco real do port

Os marcos relevantes são:

```text
dependências
↓
CMake WebKit conclui
↓
Ninja começa compilação real
↓
WTF
↓
JavaScriptCore
↓
WebCore
↓
WPE
↓
link final
↓
processo WebKit inicia no CSOS
↓
primeira página
↓
CSS
↓
JavaScript
↓
input
```

Não medir progresso apenas por número de bibliotecas adicionadas.

---

# GPU AMD e NVIDIA

AMD Radeon e NVIDIA GeForce continuam requisitos oficiais.

Nenhuma delas é opcional.

A validação física de GPU pode continuar em standby enquanto não houver máquina/mídia apropriada, como já definido anteriormente.

Isso não remove M14.

Quando houver hardware apropriado:

```text
infraestrutura compartilhada DRM/KMS
↓
AMD Radeon + AMDGPU/RADV
↓
triângulo Vulkan AMD em hardware real
↓
NVIDIA GeForce + Nouveau/NVK ou stack apropriada
↓
triângulo Vulkan NVIDIA em hardware real
```

---

# AMD

AMD continua como primeiro backend gráfico físico de referência.

Suporte AMD não significa:

```text
detecção PCI
framebuffer
ioctl simulado
teste host
```

Suporte exige progressivamente:

```text
inicialização
memória
filas
sincronização
command submission
Vulkan
```

Gate:

```text
triângulo Vulkan RADV em Radeon real
```

---

# NVIDIA

Depois do primeiro triângulo AMD real, NVIDIA passa a ser o próximo bloqueio gráfico obrigatório.

Uma máquina NVIDIA deve funcionar sem Radeon presente.

Critérios:

* [ ] registrar modelo e PCI ID;
* [ ] registrar firmware e backend;
* [ ] inicializar sistema somente com NVIDIA;
* [ ] display funcional;
* [ ] memória GPU funcional;
* [ ] filas funcionais;
* [ ] sincronização funcional;
* [ ] executar triângulo Vulkan real;
* [ ] persistir backend escolhido em `/data/config/hardware.csc`;
* [ ] registrar evidência reproduzível.

Detecção PCI não conta.

Framebuffer não conta.

Build NVK no host não conta.

---

# Autoconfiguração de hardware

Durante instalação:

```text
hardware discovery
↓
topologia
↓
benchmarks limitados
↓
seleção de políticas
↓
/data/config/hardware.csc
```

Defaults versionados permanecem em:

```text
/system/config/defaults/
```

Boot normal:

```text
validar hardware
↓
carregar /data/config/hardware.csc
↓
aplicar configuração
```

Descoberta pesada não deve ocorrer em todo boot.

Se hardware mudar, recalibrar apenas o necessário.

---

# Interface e compositor

O compositor CSOS deve continuar responsável por:

```text
surfaces
foco
input
damage
present
window lifecycle
```

WebKit é responsável pela interface HTML/CSS/JS.

Separação:

```text
hardware/input
↓
CSOS compositor/window manager
↓
WPE WebKit surface
↓
HTML/CSS/JS
```

A interface deve permanecer editável sem recompilar o kernel.

---

# Estrutura da UI

Conceitualmente:

```text
/system/ui/
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

Providers são leitura.

Scripts/actions são ação autorizada.

HTML ou JavaScript não pode executar comandos arbitrários sem passar pelo backend/capabilities do sistema.

---

# Alt+Tab e lifecycle

Manter o lifecycle:

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

Alt+Tab deve trabalhar junto desse lifecycle.

Aplicações congeladas não devem continuar competindo normalmente com o jogo.

---

# Modos de execução

## NORMAL

Pode executar:

```text
Git
Nix
downloads
diagnósticos
serviços
UI completa
background
```

## GAME

Priorizar:

```text
jogo
input
network
áudio
display
```

Reduzir background.

## MATCH

Prioridade máxima para a partida.

Por padrão:

```text
Git auto operations = OFF
Nix operations      = OFF
system GPU compute  = OFF
background optional = FROZEN/OFF
```

Nenhum updater ou daemon relacionado a Git/Nix deve interferir no frametime.

---

# GPU compute do sistema

Somente utilizar GPU para tarefas do sistema quando houver ganho medido.

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

Avaliar:

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

Implementar ABI Linux conforme software real exigir.

Não implementar syscalls apenas porque Linux possui.

Fontes de requisitos reais:

```text
BusyBox
Git
SSH
Nix
WPE WebKit
Mesa
RADV
NVK
SDL
Steam Runtime
Steam
CS2
```

Fluxo:

```text
software real falha
↓
identificar contrato ausente
↓
implementar corretamente
↓
teste
↓
continuar
```

---

# Ordem das milestones originais

As milestones existentes continuam válidas.

A nova fase P0–P4 é um **priority override temporário**, não motivo para jogar fora o progresso anterior.

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
M20  WebKit / HTML UI Runtime
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

Não renumerar todo o projeto apenas por causa de P0–P4.

Registrar P0–P4 como infraestrutura transversal/prioridade temporária.

---

# Estado conhecido das milestones

## M0–M13

Possuem fundações importantes implementadas:

```text
build
boot
memória
CPU/SMP
scheduler
userspace
Linux ABI inicial
BusyBox
PCIe
NVMe
filesystem
USB/xHCI
rede
áudio
```

Isso não implica validação completa em todo hardware.

---

# M14 — GPU/Vulkan

Parcial.

Já existe infraestrutura significativa AMD/DRM e testes de host/userspace.

Isso não equivale a Vulkan validado em hardware.

Ainda faltam gates físicos fundamentais.

M14 permanece aberta até AMD e NVIDIA suportadas completarem validação exigida.

---

# M15 — SDL

Parcial.

Existe infraestrutura software de:

```text
surfaces
eventos
teclado
mouse
roda
áudio software
blit
```

Continuar somente quando estiver no caminho necessário para UI/WebKit/aplicações.

Não refatorar SDL indefinidamente sem um consumidor real.

---

# M16 — Hardware discovery/autotune

Parcial.

Atualizar o caminho antigo:

```text
/system/config/hardware.csc
```

para:

```text
/data/config/hardware.csc
```

com defaults em:

```text
/system/config/defaults/
```

Persistência e retuning físico continuam pendentes.

---

# M17 — Gaming Optimization

Somente otimizar depois de existir baseline reproduzível.

Medir:

```text
scheduler
IRQ
input
rede
NVMe
áudio
frametime
1% low
0.1% low
FPS
```

Não aceitar otimização apenas teórica.

---

# M18–M19

Lifecycle, freeze, reclaim e standby possuem bases já implementadas/testadas.

Continuar validação real conforme o sistema amadurecer.

Não reabrir essas milestones para refactors cosméticos enquanto gates mais importantes estiverem pendentes.

---

# M20–M23 — UI

A prioridade principal desta faixa passa a ser explicitamente:

```text
WPE WEBKIT REAL
```

O compositor nativo e parser HTML atual são bootstrap.

Não gastar ciclos tentando transformar o parser bootstrap em substituto do WebKit.

---

# M24–M26

GPU para shell/compute/autotune somente quando:

```text
Vulkan estiver funcional
+
houver workload real
+
ganho puder ser medido
```

Não antecipar.

---

# M27 — Steam Runtime

Somente depois do SO funcional.

Usar Steam Runtime real para descobrir incompatibilidades restantes da ABI.

Não criar compatibilidade fictícia antecipadamente.

---

# M28 — Steam

Critérios mínimos:

```text
iniciar
login
UI funcional
biblioteca
download
processos auxiliares
rede
áudio/input necessários
```

---

# M29 — Counter-Strike 2

Ordem:

```text
processo inicia
↓
menu
↓
renderização
↓
input
↓
áudio
↓
partida offline
↓
servidor
↓
partida completa
```

Não tentar alterar, contornar ou enganar VAC.

---

# M30 — Integração final

Validar:

```text
instalação
Git update
Recovery
SSH
Nix
WebKit
UI
hardware
Vulkan
Steam
CS2
estabilidade
performance
```

---

# Ordem operacional resumida

A IA/agente deve consultar esta sequência quando decidir a próxima tarefa.

## AGORA

```text
1. P0 — separar /system de /data
2. P1 — Git update real
3. P2 — Alpine Recovery + bare-metal
4. P3 — SSH/rede para desenvolvimento
5. P4 — Nix mínimo
```

## DEPOIS, SEM DESVIO

```text
6. voltar ao WPE WebKit exatamente do gate atual
7. fazer WebKit realmente executar no CSOS
8. integrar HTML/CSS/JS à UI
9. concluir componentes SDL/UI necessários
10. continuar ABI por demanda real
11. validar hardware discovery
12. retomar AMD/NVIDIA física quando possível
13. medir e otimizar GAME/MATCH
14. Steam Runtime
15. Steam
16. CS2
17. integração/performance final
```

---

# Regra de retorno automático

Esta regra é obrigatória:

> Assim que P0–P4 satisfizerem seus critérios mínimos de aceitação, nenhuma delas continua sendo prioridade.

A prioridade seguinte torna-se imediatamente:

```text
WPE WebKit
```

Não pedir nova confirmação.

Não inventar nova etapa intermediária.

Não continuar melhorando Nix.

Não continuar melhorando Alpine.

Não criar A/B.

Não criar updater.

Não criar package manager.

Retomar o gate WebKit mais recente.

---

# Commits

Commits devem representar progresso verificável.

Preferir:

```text
uma mudança lógica
+
teste
+
gate avançado
```

Não fazer commit apenas para aumentar atividade aparente.

Não fragmentar uma única correção artificialmente em muitos commits sem necessidade.

Também não acumular uma mudança enorme quando ela pode ser validada incrementalmente.

---

# Atualização do GOAL

Depois de progresso real:

* atualizar somente fatos que mudaram;
* não transformar GOAL em log detalhado de cada microcommit;
* registrar gates concluídos;
* registrar bloqueio atual;
* registrar próxima tarefa;
* preservar critérios ainda pendentes.

Detalhes extensos de implementação devem preferencialmente ficar em documentos específicos ou histórico Git.

---

# Relatório de progresso

Quando solicitado a informar status, distinguir explicitamente:

```text
implementado
testado no host
testado no QEMU
testado em hardware real
validado
```

Nunca tratá-los como equivalentes.

Não aumentar porcentagem apenas por:

```text
documentação
stubs
mock
fixture
detecção
teste de host
```

---

# Hardware real

Resultado real possui peso maior que simulação quando o requisito é físico.

Exemplo:

```text
PCI device encontrado no Windows host
```

não prova driver CSOS.

```text
QEMU framebuffer funcionando
```

não prova Radeon/NVIDIA.

```text
RADV compila
```

não prova Vulkan físico.

---

# Performance

Não assumir:

```text
menos código = mais FPS
```

Medir.

Prioridades de performance:

```text
frametime consistente
>
latência
>
0.1% low
>
1% low
>
FPS médio
```

Uma otimização que aumenta FPS médio mas piora consistência pode ser rejeitada.

---

# Baseline

Comparar quando possível:

```text
Windows
Linux otimizado
CSOS
```

com:

```text
mesmo hardware
mesmo jogo
mesma versão
mesmas configurações
mesma resolução
mesmo cenário
```

---

# Definition of Done — infraestrutura de desenvolvimento

Antes do desenvolvimento bare-metal contínuo ser considerado funcional:

```text
instalar CSOS
↓
boot NVMe
↓
rede
↓
Git
↓
git pull
↓
reboot
↓
nova versão
```

e:

```text
CSOS quebrado
↓
Alpine
↓
rede/SSH
↓
montar CSOS
↓
Git
↓
restaurar
↓
reboot
↓
CSOS
```

e:

```text
Nix
↓
hello
↓
curl HTTPS
↓
reboot
↓
persistência
```

---

# Definition of Done — interface

```text
boot
↓
sessão gráfica
↓
WPE WebKit real
↓
HTML
↓
CSS
↓
JavaScript
↓
DOM
↓
input
↓
backend CSOS
```

---

# Definition of Done — GPU

AMD suportada:

```text
boot real
↓
driver
↓
memória
↓
filas
↓
sincronização
↓
Vulkan
↓
triângulo
```

NVIDIA suportada:

```text
boot real sem AMD
↓
driver
↓
memória
↓
filas
↓
sincronização
↓
Vulkan
↓
triângulo
```

---

# Definition of Done — projeto

O GOAL somente pode ser considerado concluído quando uma máquina suportada executar:

```text
UEFI
↓
CSOS
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
Counter-Strike 2
↓
partida completa
```

e também provar recuperação:

```text
quebrar CSOS
↓
Alpine Recovery
↓
Git
↓
CSOS recuperado
```

---

# Resumo arquitetural

```text
                         GITHUB
                           │
                           │ git pull
                           ▼
                    ┌──────────────┐
                    │     CSOS     │
                    │ laboratório  │
                    └──────┬───────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
       WebKit             Nix             Vulkan
         │                 │                 │
         ▼                 ▼                 ▼
        UI               Apps              Steam
                                               │
                                               ▼
                                              CS2


Se quebrar:

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

---

# Próxima decisão do agente

Sempre identificar:

```text
QUAL É O PRIMEIRO GATE NÃO CONCLUÍDO?
```

Durante a fase excepcional:

```text
P0 → P1 → P2 → P3 → P4
```

Depois:

```text
WPE WebKit → UI → restante do roadmap
```

Não trabalhar no último item interessante encontrado no código.

Trabalhar no primeiro bloqueio real da sequência.

---

# Regra final

O objetivo não é produzir a maior quantidade possível de código.

O objetivo é diminuir continuamente a distância entre:

```text
CSOS atual
```

e:

```text
notebook real
↓
CSOS instalado
↓
Git atualizável
↓
recuperável pelo Alpine
↓
Nix funcional
↓
desktop WebKit real
↓
Vulkan real
↓
Steam
↓
CS2
↓
partida competitiva com performance mensurável
```

Cada mudança deve mover o projeto nessa direção.
