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

Estado do requisito NVIDIA em 2026-09-07: **0% validado em hardware e ainda
pendente**. Há infraestrutura genérica que poderá ser reutilizada, mas ela não
deve ser contabilizada como backend NVIDIA até uma GeForce executar o caminho
completo. A próxima frente continua sendo concluir AMD/RADV; imediatamente após
o triângulo AMD real, NVIDIA passa a ser o bloqueio principal de M14. Steam
Runtime, Steam e CS2 permanecem posteriores à conclusão funcional do SO e dos
dois backends gráficos.

Critérios de aceitação específicos para NVIDIA (ainda pendentes):

- [ ] Registrar a GeForce validada, PCI ID, família, firmware, driver e backend Vulkan utilizados.
- [ ] Inicializar o instalador e o SO em máquina somente NVIDIA, sem dependência de AMD.
- [ ] Validar memória GPU, filas e sincronização, além de display básico.
- [ ] Executar um triângulo Vulkan real e reproduzível nessa GeForce.
- [ ] Registrar um log físico verificável que prove cada gate NVIDIA; resultado de QEMU, fixture ou simples detecção PCI não vale como conclusão.
- [ ] Selecionar e persistir o backend correto em `hardware.csc`.
- [ ] Publicar uma matriz NVIDIA por modelo/PCI ID, distinguindo validado, experimental e não suportado, com procedimento e evidências de validação reproduzíveis.

Esses critérios integram M14 e não devem ser adiados para depois de Steam/CS2.
Adicionar o requisito à documentação não significa que o driver já esteja
implementado ou validado, nem aumenta a porcentagem concluída do projeto.

## Ordem das milestones

- [x] **M0–M13 — fundações do SO:** build, boot, memória, CPU/SMP, scheduler, userspace, ABI Linux inicial, BusyBox, PCIe, NVMe, filesystem, USB/xHCI, rede e áudio possuem fundações implementadas; integração e validação final ainda continuam.
- [ ] **M14 — GPU AMD/NVIDIA + Vulkan:** parcial. A preparação AMD GFX11, `AMDGPU_INFO_DEV_INFO`, `AMDGPU_INFO_MEMORY`, a leitura restrita do `GB_ADDR_CONFIG` físico e as consultas obrigatórias de firmware ME/MEC/PFP possuem implementação e testes de host. As versões vêm dos blobs GFX11 selecionados e validados. O contrato GPUVA já faz o libdrm derivar `address32_hi = 0`, e DRM 3.54 só é anunciado quando os perfis físico/memória/firmware, allocator VRAM e command submission estão instalados; `ACCEL_WORKING` exige perfis válidos e um callback de saúde instalado após o teste PM4 físico; retorna zero sem esse callback ou quando a fila/GART fica indisponível. O bit permite iniciar libdrm/RADV para validação, não certifica Vulkan. GEM aceita placement real na VRAM visível, mantém endereços CPU/MC separados, instala PTEs GPUVA sem atributos de memória de sistema, atualiza uso/capacidade das heaps VRAM e GTT e aplica semântica explícita aos flags de criação usados pelo RADV. `AMDGPU_CS` aceita a BO list inline e até 192 IBs GFX do RADV atual, com validação individual, residência, BOs `VM_ALWAYS_VALID` e uma única conclusão física. Capacidade PCIe combinada, tipo/largura de VRAM via ATOM, clocks e snapshots físicos de CUs/RBs/TCC/UMCs ativos também estão cobertos. A identidade PCI Linux compartilhada agora publica major/minor dos nós DRM, `uevent`, IDs PCI reais e o vínculo de subsistema exigido por `drmGetDevice2`, com `readlink`/`readlinkat`; testes de host e Ring 3 comprovam `card0`, `renderD128` e os arquivos sysfs pela ABI Linux. VRAM não visível ainda não é alocável. Shadow/CSA/userq permanecem corretamente desabilitados; validação do libdrm no userspace real, execução Radeon real e triângulo RADV ainda faltam. Depois do triângulo AMD, NVIDIA/NVK ou stack compatível deve funcionar de forma independente em uma máquina somente NVIDIA e também exige validação real de inicialização, memória, filas, sincronização e triângulo Vulkan.
- [ ] **M15 — SDL:** parcial. Foi criado o contrato software inicial (`graphics/sdl.zig`) com superfície RGBA, janela, fila de eventos quit/teclado/mouse (incluindo roda), `peek`/estado do último evento e dispositivo de áudio com validação de especificação, coberto por teste host; eventos consecutivos de mouse são coalescidos sem atravessar transições de botão e com saturação de deltas. O loop HID do kernel converte teclado/mouse/roda para essa fila, fornece feedback visual e `display.blitSurface` copia superfícies SDL ao backbuffer. O áudio software expõe profundidade/disponibilidade, pausa, drenagem e limpeza de fila. Faltam compositor SDL completo, integração do áudio com hardware e aplicações SDL reais.
- [ ] **M16 — hardware discovery/autotune:** parcial. O boot de instalação já executa descoberta, benchmarks limitados, gera/verifica `/system/config/hardware.csc` e emite `CSOS M16 hardware profile ready`; ainda falta validar seleção persistida e retuning após troca de hardware em máquinas físicas AMD e NVIDIA.
- [ ] **M17 — otimização para jogos:** scheduler, IRQ, input, rede, NVMe, áudio, GAME e MATCH medidos contra baseline.
- [ ] **M18–M19 — ciclo de processos e standby:** freeze, reclaim seguro e retomada.
- [ ] **M20–M23 — interface do sistema:** parcial. O framebuffer agora possui um window manager/compositor software com criação/fecho de janelas, foco, hit-test, Alt+Tab, arrasto limitado à tela e composição por camadas, testável em QEMU; a integração SDL software inicial já cobre superfície, eventos e contrato de áudio, faltando texto completo, ligação de todos os eventos ao gerenciador, runtime HTML/CSS/Jinja, aplicações e UI dinâmica.
- [ ] **M24–M26 — aceleração e autotune de GPU do sistema:** somente onde houver ganho medido; desativado por padrão em MATCH.
- [ ] **M27 — Steam Runtime:** corrigir a ABI necessária somente após o SO estar funcional.
- [ ] **M28 — Steam:** abrir, autenticar, exibir biblioteca e baixar jogos.
- [ ] **M29 — CS2:** iniciar, abrir menu, jogar offline, entrar em servidor e concluir uma partida.
- [ ] **M30 — integração final:** validar todo o fluxo, estabilidade e performance.

## Progresso atual

Snapshot em 2026-09-07, ponderado por funcionalidade real:

```text
concluído: aproximadamente 40%
restante:  aproximadamente 60%
```

Prioridade operacional atualizada: a validação de GPU física AMD/NVIDIA fica
em **standby** até haver máquina/mídia dedicada. Enquanto isso, o trabalho
continua no caminho emulado do QEMU para tornar o sistema utilizável, começando
por SDL e pela primeira sessão gráfica. O requisito de ambas as GPUs permanece
obrigatório e volta a ser executado antes de Steam/CS2.

O framebuffer atual já produz uma saída visual verificável (`zig-out/display.png`)
com painel de status, barra, cursor e elementos de diagnóstico. Isso é um
primeiro passo gráfico em QEMU e já é uma sessão interativa básica: SDL software,
eventos de teclado/mouse, compositor, janelas, foco e FILES estão ligados ao
loop principal. Ainda faltam texto completo, runtime HTML/CSS/Jinja, áudio SDL
real e aplicações completas. O cursor acompanha deltas de mouse USB com
redesenho seguro; cliques e estado dos botões são refletidos visualmente e no
serial, enquanto o gerenciamento de janelas cobre o conjunto atualmente
implementado abaixo.
O delta do mouse normaliza a posição antes de aplicar movimento, mantendo o
cursor dentro da tela mesmo após uma mudança de resolução ou estado inválido;
a fila SDL preserva eventos `quit` mesmo quando está saturada.
O painel também ganhou uma fonte bitmap mínima para o rótulo `READY`, tornando
o estado de inicialização legível sem depender de uma console serial.
O primeiro widget clicável alterna estado com botão esquerdo, altera sua cor e
emite `UI action button: active/inactive` no serial. A camada `WindowManager`
fornece composição software, criação/fecho, foco, hit-test e Alt+Tab; as janelas
podem ser arrastadas pela barra de título, fechadas pelo botão visual ou com
`Esc`, e a janela focada é elevada para o topo. Integração de aplicações,
texto completo e runtime HTML/CSS/Jinja continuam pendentes.
`Ctrl+W` também fecha a janela focada como atalho equivalente para uso por
teclado.
`Alt+F4` fornece o atalho padrão de fechamento da janela focada.
O launcher separa seleção de teclado do hover do mouse: apontar para um item
apenas realça sua célula, enquanto setas/roda preservam a seleção ativa; ao sair
do menu o hover é limpo sem perder a seleção.
O FILES também acompanha o hover do ponteiro nas linhas visíveis; o clique segue
reservado para abrir o preview do arquivo.
No preview, o botão `BACK` também recebe realce ao passar o ponteiro antes do
clique de retorno.
O teclado também usa `Home`, `End`, `PageUp` e `PageDown` para navegar entre
blocos da prévia.
`Space` avança uma página enquanto a prévia está aberta.
`Enter` oferece o mesmo avanço por teclado.
Na lista, `Space` abre o item selecionado como alternativa ao `Enter`.
No ciclo de standby, páginas somente-leitura da imagem principal podem ser
descartadas e restauradas; intérprete e bibliotecas compartilhadas permanecem
residentes até haver metadado de backing individual para recuperação segura.
Na rede, DNS correlaciona IDs de transação, ICMP exige a sequência da sondagem
e ARP rejeita MACs de emissor vazios ou broadcast.
O runner QEMU agora possui `-SmokeDesktopMouse`, que injeta movimento relativo
um evento de roda e um ciclo de botão esquerdo no dispositivo USB emulado; o
teste exige movimento, `UI mouse wheel` e os marcadores `UI mouse buttons: 1/0`.
O `test-system.ps1` combina esse smoke com
o fluxo de teclado/FILES, mantendo a validação limitada ao hardware emulado.
O espaçamento entre comandos evita perder deltas por coalescência do dispositivo.
`Ctrl+M` minimiza/restaura a janela focada; janelas minimizadas deixam de
participar do hit-test e da composição até serem restauradas por `Alt+Tab`.
A composição também exibe uma barra de tarefas software, com botões para
restaurar/focar qualquer janela.
`Alt+Shift+Tab` percorre as janelas no sentido reverso.
`Alt+Tab` agora abre um switcher visual no topo da composição, destaca a janela
selecionada e permanece até Alt ser solto; `Esc` cancela apenas o overlay. O
atalho global deixa de vazar para a fila SDL da aplicação focada.
As janelas agora possuem títulos próprios e podem ser maximizadas/restauradas
pelo botão da barra de título ou por `Ctrl+Seta para cima`, preservando a
geometria anterior e respeitando a área reservada à barra de tarefas.
`Alt+F10` oferece o mesmo toggle pelo atalho padrão de desktop.
O botão de minimizar atualiza o foco para a janela visível superior; quando não
há outra janela disponível, o desktop fica corretamente sem foco até a
restauração pela barra de tarefas.
Uma alça visual no canto inferior direito permite redimensionamento por mouse,
com dimensões mínimas e contenção integral na área útil do desktop.
O botão `CS` na barra de tarefas abre um lançador com `APP1` e `MONITOR`.
Selecionar uma aplicação fechada recria sua janela; selecionar uma existente a
restaura e leva ao foco, completando o primeiro ciclo abrir/usar/fechar/reabrir.
O mesmo fluxo funciona sem mouse: `Super` ou `Ctrl+Espaço` alterna o lançador,
setas percorrem as opções, `Enter` ativa e `Esc` fecha o menu sem fechar a
aplicação focada. O toggle possui debounce e o atalho alternativo evita captura
da tecla Super pelo host do QEMU.
Com o lançador aberto, as teclas `1`–`4` selecionam diretamente as quatro
aplicações disponíveis.
`Space` também confirma a aplicação selecionada no launcher.
`Ctrl+Alt+T` abre ou focaliza diretamente o TERMINAL.
`Ctrl+Alt+M` abre ou focaliza diretamente o MONITOR.
`Ctrl+Alt+S` abre SYSTEM e `Ctrl+Alt+F` abre/atualiza FILES diretamente.
`Ctrl+Alt+L` alterna diretamente o launcher.
A tabela fixa do compositor saiu do frame de `kernel.start` para não consumir a
stack limitada recebida do firmware; o boot QEMU voltou a alcançar a sessão
gráfica depois dessa correção.
Sob carga, movimentos de mouse consecutivos são coalescidos na fila SDL para
preservar responsividade sem sobrescrever eventos de botão/roda.
A fila HID xHCI aplica a mesma proteção antes da camada SDL: quando cheia,
combina apenas movimentos consecutivos com o mesmo estado de botões, satura os
deltas e contabiliza separadamente coalescência e descarte real.
O boot também cria uma superfície SDL software de demonstração, desenha nela e
a apresenta dentro de `APP1` por `blitSurface`. A aplicação agora consome a fila
SDL real: teclado, movimento, roda e botões alteram o conteúdo, e `Ctrl+Q`
encerra a aplicação. A entrega ocorre apenas quando `APP1` possui foco. Isso
valida o primeiro ciclo interativo completo, incluindo roteamento de input, de
uma aplicação gráfica sem GPU física.
`APP1` possui agora um buffer de texto ASCII editável, com inserção no cursor,
Backspace, navegação por setas e renderização bitmap completa de letras e
números. O evento SDL de texto é separado do scancode de teclado.
O buffer alimenta um terminal gráfico não bloqueante com comandos internos
`help`, `status`, `version`, `whoami`, `pwd`, `ls`, `echo`, `history`, `clear` e `reset`, prompt, cursor e saída
persistente. Ele não substitui
a futura integração concorrente do BusyBox, mas restaura uma superfície de
comando utilizável sem suspender o loop do desktop.
O terminal mantém quatro comandos de histórico, recuperáveis por setas, oferece
Home/End/Delete, `Ctrl+A/E/U/K/C/D`, `Ctrl+Backspace` e `Ctrl+Seta` para navegação
por palavras, e renderiza automaticamente
as seis linhas mais recentes.
O terminal gráfico agora executa `cat /hello.txt` contra o arquivo virtual do
initramfs e retorna erro explícito para caminhos ausentes, além de listar `CAT`
no help.
`Ctrl+R` também recupera a entrada anterior, como em shells convencionais.
O compositor associa a superfície SDL à janela proprietária e aplica clipping
à área de conteúdo; a aplicação deixa de atravessar bordas ou aparecer por cima
de janelas que estão adiante na ordem de composição.
O blit SDL converte RGBA8888 para RGB nativo e aplica alpha blending por pixel,
cobrindo framebuffers RGB/BGR sem copiar canais ou alpha como se fossem pixels
nativos.
O display mantém um frontbuffer sombra: o primeiro frame é integral, e os
seguintes eliminam escritas MMIO de pixels idênticos dentro da região suja.
Contadores distintos medem pixels examinados e realmente apresentados.
`MONITOR` deixou de ser decorativo e possui superfície SDL própria com frames,
pixels examinados, escritas efetivas e percentual economizado. Isso valida duas
aplicações reais na mesma ordem de composição.
O runner QEMU também passou a usar encerramento direto e limitado do PID antes
do fallback por árvore, eliminando um travamento observado no cleanup de um
smoke test sem deixar o emulador aberto.

Após esses incrementos, `zig build` recompila o EFI em `14/14` etapas e
`zig build test` conclui `41/41` etapas e `197/197` testes aprovados; um boot QEMU limitado também voltou a alcançar
`CSOS graphical session ready`.

O caminho NVMe agora enumera a lista de namespaces ativos em vez de tratar o
maior NSID anunciado pelo controlador como contagem de discos. O NSID
descoberto alimenta Identify Namespace e todo I/O; validações de host cobrem
lista vazia, NSID inválido e IDs esparsos. No boot QEMU limitado, o log mudou de
256 para `NVMe namespaces: 1`, seguido por read/write, FAT16 e sessão gráfica
prontos, e o emulador foi encerrado ao terminar o teste.

Identify Namespace agora valida `NSZE`, capacidade utilizável, tamanho do bloco
e ausência de metadata por LBA antes de habilitar I/O. O controlador mantém a
contagem real de blocos e rejeita LBAs fora do namespace sem publicar comandos.
O QEMU confirmou `131072 blocks x 512 bytes`, read/write, FAT16 e desktop, com
encerramento automático ao final.

O mount FAT16 agora valida o BPB contra a geometria NVMe antes de qualquer
navegação: assinatura, setor, cluster, regiões reservadas, capacidade das FATs,
faixa FAT16 e limite total do dispositivo. Casos malformados possuem testes de
host; a imagem real passou pelo novo gate e manteve write, filesystem e desktop.

Overwrite de arquivo FAT16 agora é transacional dentro do modelo atual: mantém
a cadeia antiga até gravar e publicar a nova, faz rollback dos clusters novos
em falha e só então recupera a cadeia anterior. A liberação possui limite de
travessia e rejeita clusters fora do volume, impedindo loops em FAT corrompida.

Escritas FAT16 não possuem mais o teto de 32 clusters imposto por um array na
stack. Alocação e gravação são incrementais, com rollback ancorado no primeiro
cluster; arquivos agora são limitados pelo volume e pelo tamanho FAT de 32 bits.

Leitura e escrita na raiz distinguem arquivos regulares de LFN, diretórios,
rótulos e entradas apagadas. Arquivo vazio retorna zero bytes, e colisões com
objetos não regulares são recusadas sem sobrescrever metadados.

O loop gráfico aplica o deslocamento do pacote HID antes de despachar a
transição de botão do mesmo pacote. Hit-tests deixam de usar a coordenada
anterior em movimento+clique, e a saturação do ponteiro nas bordas é testada.

O launcher passou de duas entradas genéricas para três aplicações nomeadas:
`TERMINAL`, `MONITOR` e `SYSTEM`. A nova janela SYSTEM possui superfície SDL
própria e apresenta estado do SO, capacidade NVMe, dispositivos USB de input e
endpoints de áudio; mouse e teclado percorrem o mesmo caminho de launch/restore.
Sua superfície é atualizada a cada ciclo do desktop, refletindo mudanças nos
dispositivos observados após o boot.
O redesenho é condicionado a mudanças nos valores, evitando trabalho repetido
quando o estado permanece estável.

O volume FAT16 agora enumera arquivos regulares da raiz com limite explícito do
buffer de saída. A quarta aplicação SDL, `FILES`, mostra nomes 8.3 e tamanhos;
o boot QEMU enumerou sete entradas reais antes de liberar o desktop.

A BSS adicional revelou um estouro preexistente da stack UEFI no autoteste GART.
O rollback AMD foi migrado para captura/aplicação/restauração in-place no
workspace global já destinado ao bootstrap, removendo cópias grandes por valor.
Marcadores por fase confirmaram o GART pronto e o boot completo após a correção.

A aplicação `FILES` agora enumera até 32 entradas, apresenta sete por viewport
e permite selecionar por setas ou roda do mouse; Enter publica nome e tamanho do
item. Home/End saltam para o primeiro/último item e PageUp/PageDown avançam uma
página da lista pelo teclado.
`F5` e `Ctrl+R` atualizam a enumeração do volume.
No MONITOR focado, `Ctrl+R` zera os contadores de telemetria para uma nova medição.
item. O QEMU encontrou 14 arquivos reais, exercitando rolagem além da primeira
tela antes de chegar ao desktop.

Enter em `FILES` abre uma prévia limitada a 192 bytes lidos do arquivo real.
Quebras de linha são preservadas, bytes binários são sanitizados e Esc volta à
lista antes de participar do fechamento normal da janela.

Seleção em `FILES` agora aceita clique direto nas linhas do conteúdo. O hit-test
considera posição da janela, margem da superfície, viewport rolado, altura útil
da linha e quantidade real de arquivos, sem conflitar com drag da barra de título.

O mouse completa o ciclo de `FILES`: clique numa linha abre a prévia real e o
botão `BACK` retorna à lista. Retângulos interativos do conteúdo respeitam a
área recortada da janela em qualquer posição e tamanho.

Abrir/restaurar `FILES` ou pressionar F5 relê a raiz FAT16. O modelo atualiza a
contagem preservando seleção/viewport válidos e faz clamp quando a lista diminui,
evitando que a interface permaneça presa ao snapshot criado durante o boot.

A prévia de `FILES` pagina o conteúdo em blocos fixos de 192 bytes com Page
Up/Down, Home e roda do mouse. O offset visível é mostrado e a navegação satura
em zero/EOF, permitindo leitura de arquivos grandes sem alocação proporcional.

O smoke QEMU pode agora operar o desktop via monitor HMP efêmero. A sequência
automatizada abriu launcher, selecionou FILES e abriu `SYSTEM.TXT` de 25 bytes,
confirmada por `UI files selected:`. `test-system.ps1` usa esse gate interativo
no lugar do boot normal que apenas aguardava o desktop.

O gate interativo foi ampliado para selecionar `LIBCSOS.SO` de 2200 bytes,
avançar ao offset 192, voltar ao offset 0 e fechar a prévia. O runner exige todos
os marcadores de launch, seleção, paginação e retorno antes de declarar sucesso.

Esta porcentagem não é uma contagem simples de milestones. M0–M13 têm bases relevantes, mas M14 ainda não possui triângulos Vulkan validados em AMD e NVIDIA, e M15–M30 permanecem majoritariamente pendentes. Código preparatório ou teste no host não equivale a hardware funcional.

Verificação mais recente em 2026-09-07: `zig build test` concluiu `41/41` etapas
e `197/197` testes, e o boot QEMU chegou a `Linux PIE userspace ready`. A
sessão gráfica assume teclado e mouse sem aguardar a saída do shell BusyBox e o
terminal já voltou como aplicação não bloqueante; isso não altera a ausência de
validação Vulkan física.
O `tools/test-system.ps1` também passou o smoke integrado de launcher, FILES,
prévia/paginação, teclado e mouse, encerrando o QEMU automaticamente após os
marcadores esperados.

O carregador ELF agora valida também o fim do trecho de arquivo e todas as
adições usadas para copiar páginas PT_LOAD, incluindo conversões para índices
do buffer. Um ELF malformado não pode mais transformar overflow em escrita fora
da imagem durante carga ou retomada de página.

O scheduler não reporta mais `sleep_ticks` residuais de threads congeladas;
somente threads no estado `sleeping` contam para o tempo de sono do grupo.
A construção da pilha inicial ELF agora valida cada reserva e o tamanho total
de `argv`/`auxv`, recusando overflow antes de escrever fora da pilha.
Ela também valida a tabela `PT_LOAD` antes de consultar seus cabeçalhos durante
a montagem do stack, fechando o último leitor ELF sem limite de imagem.
O coletor de construtores e a descoberta do interpretador agora verificam
overflow de base/offset e limites de cabeçalhos e strings antes de usar os
endereços calculados.
A resolução de dependências `DT_NEEDED` recebe o mesmo preflight e rejeita
somatórios embrulhados ao localizar nomes na tabela dinâmica.
O parser GNU hash também verifica os tamanhos de bloom, buckets e chains antes
de calcular qualquer índice de símbolo.
O avanço do índice de chain e do maior símbolo usa soma checked, evitando loop
infinito em tabelas que atingem `u32` máximo.
O carregamento de uma dependência fecha o descritor mesmo quando a leitura
termina prematuramente, evitando vazamento de handles no loader.
As rotas VFS para propriedades DRM com sufixo agora comparam comprimentos por
subtração, sem somar tamanhos controlados pelo caminho antes do slicing.
Relocações simbólicas validam a soma entre valor do símbolo e base do módulo
antes de gravar o destino, rejeitando endereços que ultrapassem `u64`.
Índices de símbolos vindos das relocations agora precisam estar dentro de
`symbol_count`, com offsets de entradas convertidos de forma checked.
`dynamicSymbols` exige que a tabela dinâmica caiba no objeto e os caminhos
`DT_VERNEED`/`DT_VERDEF` usam somas checked para avançar e resolver strings.
Os índices `versym` agora validam multiplicação, soma, conversão e dois bytes
disponíveis antes de ler versões exigidas ou definidas.
O salto inicial para a lista auxiliar `DT_VERNEED` também usa adição checked.
Os cálculos de páginas do staging e carregamento de firmware GPU arredondam
tamanhos com soma checked antes de alocar memória DMA.
O handoff PSP também valida arredondamento, multiplicações, limites da reserva
alinhada e registra a alocação antes de qualquer falha, garantindo rollback.
O cálculo do tamanho das tabelas VM AMD usa multiplicação e arredondamento
checked, preservando o contrato mesmo com futura expansão do limite.
O caminhamento de capabilities PCI rejeita ponteiros não nulos desalinhados ou
fora do intervalo antes de seguir para o próximo registro.
O E1000 valida anéis e todos os buffers DMA antes de programar seus registradores,
recusando endereços fora da máscara do dispositivo.
O xHCI valida DCBAA, command ring, event ring e ERST antes de escrever seus
ponteiros nos registradores do controlador.
Rings, relatórios HID e contexts alocados por dispositivo e pelo áudio também
passam pela validação DMA antes de configurar endpoints.
Contexts de slot, input, transfer ring e descriptor alocados durante a
enumeração também são validados antes de `Address Device`.
Buffers de sample-rate, sample, tons e períodos de áudio xHCI passam pelo gate
DMA e são liberados imediatamente se a validação falhar.

Mapeamentos anônimos também possuem rollback transacional: uma falha no meio da
criação remove as páginas já instaladas e devolve a alocação e o ownership.
Mapeamentos de dispositivo seguem a mesma regra, desfazendo páginas MMIO
parciais quando uma instalação posterior falha.
Proteção e desmontagem de regiões fazem pré-validação de todas as páginas antes
de alterar a primeira, mantendo `mprotect`/`munmap` atômicos perante buracos.

Inventário do host Windows no mesmo snapshot detectou uma AMD Radeon(TM)
Graphics (`1002:164e`) e uma NVIDIA GeForce RTX 4060 Ti (`10de:2803`), ambas
com status `OK`. Essa detecção apenas confirma que existe hardware disponível
para as próximas sessões físicas; não conta como validação AMD/NVIDIA do CSOS,
pois ainda não houve boot do SO com cada backend e triângulo Vulkan comprovados.

O Ubuntu no WSL2 também consegue consultar a RTX 4060 Ti via `nvidia-smi`
(driver 591.86), mas WSL2 não é o kernel do CSOS e essa saída continua sendo
somente evidência de disponibilidade do host, não validação NVIDIA do projeto.

O artefato UEFI atual para a próxima sessão física é
`zig-out/bin/BOOTX64.efi` (2.647.552 bytes, SHA-256
`D304CA89158E4F385FEDFF7D70F93827B8996E1A2ED680410BF9364EDCA53E87`).
Nesta sessão não há mídia removível disponível: a enumeração de discos mostrou
somente o NVMe interno do host. Portanto, a gravação/teste UEFI físico continua
pendente de uma mídia dedicada, sem qualquer alteração automática no disco do
usuário.

## Próxima rota

O runtime RADV agora possui um gate explícito para a futura apresentação sem
window system externo: antes de criar a instância, o probe enumera as extensões
e exige `VK_KHR_display`, `VK_EXT_direct_mode_display` e
`VK_EXT_acquire_drm_display`. Somente então habilita as três e emite
`RADV direct display instance extensions ready`. Falhas desse gate preservam o
status específico em vez de serem mascaradas como falha genérica de criação da
instância. O marcador passou a ser obrigatório no build e no contrato do
verificador físico. O probe, a fixture e `zig build test` passaram; o boot
limitado repetiu descoberta DRM completa, o novo marcador e
`RADV dynamic loader ready` em
`zig-out/smoke-a4c9c210d2f644eda3befbff042d809d.serial.log`. O QEMU foi
encerrado. Isso prova a disponibilidade da interface WSI no runtime empacotado,
mas ainda não prova aquisição KMS, swapchain, apresentação ou hardware Radeon.

A camada física seguinte também está preparada sem contaminar o gate offscreen:
quando existe um `VkPhysicalDevice`, o probe resolve as funções de
`VK_KHR_display`, enumera displays conectados, exige resolução física não nula,
ao menos um modo com resolução/refresh válidos e um plano que suporte o display.
Somente esse conjunto emite `RADV direct display modes and planes ready`. A
ausência de monitor não impede a coleta independente da evidência do triângulo
offscreen; `verify-radv-hardware-log.ps1 -RequireDisplayEnumeration` torna o
novo marcador obrigatório quando a validação solicitada inclui display. Build
e fixture passaram com esse contrato. O boot limitado
`zig-out/smoke-3262d7a3ed0f43728f61603af96d0c75.serial.log` confirmou que o
loader continua funcional; corretamente não emitiu o marcador físico porque o
QEMU reportou zero dispositivos Vulkan. O QEMU foi encerrado. Ainda faltam
aquisição DRM/KMS, criação de surface/swapchain, apresentação e confirmação em
Radeon real.

A dependência WSI foi corrigida para seguir o contrato Vulkan: além das três
extensões de display direto, a instância agora exige e habilita
`VK_KHR_surface`, dependência de `VK_KHR_display`. Depois de encontrar
display/modo/plano, o probe consulta `VkDisplayPlaneCapabilitiesKHR`, escolhe
extent, transformação e alpha realmente suportados, cria uma `VkSurfaceKHR`
por `vkCreateDisplayPlaneSurfaceKHR` e a destrói antes de emitir
`RADV direct display surface ready`. O verificador ganhou o gate independente
`-RequireDisplaySurface`; a fixture passou exigindo enumeração e surface. A
auditoria do runtime stripado passou com 4.423 páginas, quatro tipos de
relocation e os símbolos/strings WSI necessários. O boot limitado com as quatro
extensões habilitadas chegou novamente a `RADV dynamic loader ready` em
`zig-out/smoke-993d5f9da583485e90c8d2fa257d9457.serial.log`; sem GPU Vulkan,
corretamente não alegou surface física. O QEMU foi encerrado. Surface preparada
não equivale a swapchain nem apresentação; esses continuam pendentes.

O probe passou a reutilizar a ABI KMS já existente no kernel em vez de criar
uma interface de teste: abre o nó primary descoberto pelo libdrm, chama
`drmModeGetResources`/`drmModeGetConnector`, exige um conector conectado com ao
menos um modo e mantém o descritor vivo durante a instância Vulkan. O marcador
`RADV connected DRM KMS connector ready` comprova essa etapa. Havendo GPU
Vulkan, o mesmo conector alimenta `vkGetDrmDisplayEXT` e
`vkAcquireDrmDisplayEXT`; somente sucesso real em ambos emite
`RADV DRM display acquired`. O verificador ganhou
`-RequireDrmDisplayAcquisition`, separado dos gates de enumeração e surface. O
build e a fixture passaram. O boot limitado
`zig-out/smoke-65a7ed647fdd41cfa2bb36e227aa398a.serial.log` exerceu a ABI KMS
real do CSOS e confirmou o conector, mas não emitiu aquisição Vulkan porque o
QEMU enumerou zero dispositivos físicos Vulkan. O descritor foi fechado e o
QEMU encerrado. Aquisição em Radeon, swapchain e apresentação seguem pendentes.

O gate seguinte mantém agora a `VkSurfaceKHR` viva até depois do device e
prioriza uma família de filas que possua simultaneamente graphics e suporte de
apresentação para essa surface. O probe enumera extensões do dispositivo e só
habilita `VK_KHR_swapchain` quando ela é realmente anunciada. Nesse caso exige
surface capabilities válidas, formato, o modo FIFO obrigatório, contagem de
imagens dentro dos limites, extent definido e composite alpha suportado; cria a
swapchain, enumera suas imagens e somente então emite
`RADV direct display swapchain ready`, destruindo swapchain, device e surface
na ordem correta. O verificador ganhou `-RequireDisplaySwapchain`. Build,
fixture com todos os gates e `zig build test` passaram. O boot limitado
`zig-out/smoke-0f0fc027a26444c2bc0f8b9b2faeb1cd.serial.log` repetiu conector
KMS, extensões da instância e loader final sem alegar surface/swapchain, pois o
QEMU continuou com zero dispositivos Vulkan; o QEMU foi encerrado. O ramo de
swapchain compila com a stack real, mas só hardware Radeon pode validá-lo. Ainda
faltam adquirir uma imagem, renderizar nela, apresentar e observar conclusão.

O ciclo de apresentação inicial também está preparado com conteúdo definido,
sem confundi-lo com o triângulo final. Depois de enumerar as imagens da
swapchain, o probe cria semáforos de aquisição e render, chama
`vkAcquireNextImageKHR`, grava um command buffer que transiciona a imagem de
`UNDEFINED` para `TRANSFER_DST_OPTIMAL`, limpa para azul e transiciona para
`PRESENT_SRC_KHR`. O submit espera o semáforo de aquisição no estágio transfer
e sinaliza o semáforo consumido por `vkQueuePresentKHR`; somente present aceito
e `vkQueueWaitIdle` concluído emitem
`RADV direct display clear frame presented`. O verificador ganhou
`-RequireClearFramePresentation`. Build, fixture com todos os gates e
`zig build test` passaram. O boot limitado
`zig-out/smoke-7557df90a87f4cee97783f410ecb62c5.serial.log` confirmou KMS,
extensões e loader sem executar ou alegar o ramo de present porque não existe
GPU Vulkan no QEMU; ele foi encerrado. O ramo físico ainda precisa executar em
Radeon real, e um clear-frame apresentado não substitui o triângulo apresentado
nem a confirmação visual/fotográfica do display.

Uma auditoria do clear-frame encontrou e corrigiu duas violações antes da
validação física. A swapchain agora só é criada se
`supportedUsageFlags` contiver simultaneamente `COLOR_ATTACHMENT` e
`TRANSFER_DST`, e declara ambos em `imageUsage`; antes o command buffer limpava
por transfer sem ter solicitado esse uso. Depois de qualquer submit aceito,
`vkQueueWaitIdle` é executado mesmo se `vkQueuePresentKHR` falhar, evitando
destruir pool/semáforos ainda em uso. O inventário temporário de extensões do
device também caiu de 256 para 128 entradas para preservar margem na stack Ring
3 de 128 KiB. Build, contrato completo e `zig build test` passaram. O boot
limitado `zig-out/smoke-bc4b00c88dc64332884bb249563c6b8d.serial.log` repetiu
KMS e loader final sem falsos marcadores físicos; o QEMU foi encerrado. A
correção fortalece o caminho preparado, mas não é evidência de apresentação em
Radeon.

O frame da swapchain passou a usar os mesmos shaders SPIR-V auditados do gate
offscreen. Para o formato/extent escolhidos, o probe cria shader modules,
render pass, pipeline layout e graphics pipeline, e depois cria image view e
framebuffer para a imagem adquirida. O command buffer limpa o fundo para preto,
aplica uma barreira `TRANSFER_WRITE → COLOR_ATTACHMENT_WRITE`, inicia o render
pass com `LOAD`, liga o pipeline e executa `vkCmdDraw(3, 1, 0, 0)`; o render
pass termina em `PRESENT_SRC_KHR`. Somente submit, `vkQueuePresentKHR` e
`vkQueueWaitIdle` bem-sucedidos emitem tanto o gate do frame definido quanto
`RADV direct display triangle presented`. O verificador ganhou
`-RequirePresentedTriangle`. Build, fixture completa e `zig build test`
passaram. O boot limitado
`zig-out/smoke-d4ad5a9d35604e2e93a203ee92130597.serial.log` confirmou que o
probe ampliado carrega e chega ao gate final no ambiente sem GPU Vulkan, sem
emitir falsamente o marcador físico; o QEMU foi encerrado. O ramo apresentado
está compilado, mas o triângulo AMD continua não validado até executar em uma
Radeon real e obter evidência visual associada ao log.

A enumeração de extensões foi corrigida antes do teste físico: RADV pode
anunciar mais de 128 extensões de device, portanto o array fixo anterior podia
receber `VK_INCOMPLETE` e jamais habilitar `VK_KHR_swapchain`. Instância e
device agora usam o padrão Vulkan de duas chamadas — primeiro contam, depois
materializam exatamente o conjunto — com limites de 64 e 512 registros. Os
buffers foram movidos da stack Ring 3 para BSS; o probe resultante possui BSS de
`0x24910` bytes (aproximadamente 146 KiB), mapeado/zerado pelo loader, sem
consumir essa margem da stack de 128 KiB. Build, contrato completo e
`zig build test` passaram. O boot limitado
`zig-out/smoke-12480ff64966441385813475f0335799.serial.log` comprovou o
carregamento com o BSS ampliado, KMS, enumeração de extensões da instância e o
gate final; não alegou o ramo físico e o QEMU foi encerrado. A correção remove
um bloqueio lógico do futuro teste Radeon, mas não o substitui.

A identidade da GPU também deixou de depender da ordem de enumeração. O probe
examina até 16 objetos retornados por `drmGetDevices2`, prefere o dispositivo
PCI AMD que possua nós primary/render e guarda seus vendor/device IDs. Depois
enumera até 16 `VkPhysicalDevice`, consulta `VkPhysicalDeviceProperties` de
cada um e só continua quando encontra correspondência exata com a identidade
DRM; o novo marcador é
`RADV Vulkan device matches DRM PCI identity`. Isso impede validar por engano
uma iGPU ou outro adaptador em sistemas híbridos. O adaptador não-AMD do QEMU é
mantido apenas como fallback quando não existe Radeon e, como sua contagem
Vulkan é zero, nunca alcança o novo marcador. Build, fixture e
`zig build test` passaram. O boot limitado
`zig-out/smoke-731cb52935d749cb92368e3d624f8ec2.serial.log` repetiu KMS e o
loader final sem falsa identidade física; o QEMU foi encerrado. A seleção por
vendor/device é necessária, mas PCI domain/bus/slot/function ainda deverá ser
cruzado para distinguir duas GPUs idênticas no mesmo sistema.

O vínculo foi ampliado para o endereço PCI completo. Como a instância é Vulkan
1.0, o probe agora exige e habilita também
`VK_KHR_get_physical_device_properties2`; para cada candidato que coincide em
vendor/device, exige `VK_EXT_pci_bus_info`, encadeia
`VkPhysicalDevicePCIBusInfoPropertiesEXT` em
`vkGetPhysicalDeviceProperties2KHR` e compara domain, bus, device/slot e
function com o `drmPciBusInfo` selecionado. Ausência da extensão ou qualquer
divergência falha fechada, eliminando a ambiguidade entre duas placas do mesmo
modelo. As estruturas grandes de properties foram colocadas em BSS porque a
inicialização automática local introduzia uma referência proibida a `memset` no
probe `-nostdlib`. Build, fixture e `zig build test` passaram. O boot limitado
`zig-out/smoke-e9f8818617cc410186d31f64f4223979.serial.log` confirmou as cinco
extensões de instância, KMS e loader final sem emitir o marcador físico em zero
GPUs Vulkan; o QEMU foi encerrado. O futuro log Radeon deverá, portanto, provar
o mesmo BDF nos caminhos DRM e Vulkan antes de qualquer draw.

A evidência serial deixou de ser apenas booleana: após a correspondência, o
probe imprime `RADV matched PCI BDF: dddd:bb:ss.f`. O verificador físico agora
recusa logs sem esse campo e aceita `-ExpectedBdf` para comparar o endereço
informado pelo operador, além do PCI device ID já obrigatório. A fixture em
`0000:03:00.0` passou com o BDF esperado e foi rejeitada quando o teste pediu
`0000:04:00.0`; build e `zig build test` também passaram. Nenhum QEMU foi
iniciado neste incremento, pois esse ramo só é alcançável após enumeração de uma
GPU Vulkan física. O próximo log Radeon deverá usar `-ExpectedBdf` para ligar a
evidência ao slot exato da máquina.

A auditoria do WSI direto mostrou que surface/swapchain compiladas ainda não
significam apresentação possível no kernel atual: `wsi_common_display` depende
de client capabilities, universal planes, propriedades KMS, PRIME, property
blobs, atomic commit e eventos de page flip; o CSOS ainda cobre principalmente
o KMS legado. O primeiro contrato compartilhado foi implementado como
`DRM_IOCTL_SET_CLIENT_CAP` (`0x4010640d`). STEREO_3D e ASPECT_RATIO aceitam
enable/disable; UNIVERSAL_PLANES e ATOMIC aceitam disable, mas enable falha
fechado com `EOPNOTSUPP` até seus ioctls existirem. Capacidade desconhecida,
valor fora de 0/1 e ponteiro inválido também são rejeitados. A suíte passou
13/13 testes, incluindo a nova cobertura, e os dois boots limitados chegaram ao
console em `zig-out/smoke-bbe00c673811454aa8f8bf585b49711b.serial.log` e
`zig-out/smoke-783f622f51424dd88d8cc5fa66648abc.serial.log`. Os QEMUs foram
encerrados. Próximo bloco funcional compartilhado: plane resources/properties;
só depois atomic poderá ser habilitado honestamente.

O bloco seguinte da ABI compartilhada foi implementado:
`DRM_IOCTL_MODE_GETPLANERESOURCES` (`0xc01064b5`) e
`DRM_IOCTL_MODE_GETPLANE` (`0xc02064b6`) expõem um plano primário de ID 5,
compatível com o CRTC 1, ligado ao framebuffer ativo quando houver e com formato
`DRM_FORMAT_XRGB8888`. Capacidades zero consultam apenas contagem; buffers,
ponteiros e plane IDs inválidos falham fechados, e o render node não aceita os
ioctls KMS. O probe passou a chamar as duas funções pela libdrm real e só emite
`RADV DRM KMS primary plane ready` após confirmar possible CRTC e formato.
Build, fixture e 13/13 testes passaram. O boot RADV limitado comprovou o caminho
integrado em `zig-out/smoke-6f071cdda0b0443d8b6362ffa8d89e90.serial.log`, com
conector e plano primário antes da instância Vulkan; o QEMU foi encerrado. Ainda
faltam propriedades do plano/conector/CRTC, PRIME e atomic commit antes de
habilitar `DRM_CLIENT_CAP_ATOMIC`.

A descoberta DRM ganhou um gate adicional: antes de criar a instância, o probe
chama `drmGetDevices2(0, NULL, 0)` e exige pelo menos um dispositivo DRM. O
retorno bruto instrumentado foi `0xfffffff2`, isto é, `-EFAULT`, no boot
limitado `zig-out/smoke-57c4a30e1cdf4c9ea6d548da61a21354.serial.log`. A causa
foi localizada: `openat` rejeitava a string `/dev/dri` porque ela reside no
segmento do `libdrm.so.2` em `0x60...`, fora das regiões estáticas reconhecidas
por `validUserSlice`. O loader agora compacta seus mappings de TLS/DSOs em
intervalos contíguos exatos, e a validação de ponteiros consulta esses intervalos
sem percorrer milhares de páginas a cada syscall. Testes de host passaram. O
boot limitado `zig-out/smoke-a22eb9c766bb41c4b56d792140e558db.serial.log`
confirmou `RADV D device count: 0x00000001`, criação de instância,
`RADV V device count: 0x00000000` no adaptador QEMU e o marcador
`RADV dynamic loader ready`. O gate foi reforçado para uma segunda chamada que
materializa os `drmDevice` reais e exige identidade PCI, vendor não nulo e nós
primary/render antes de liberar os objetos. O boot limitado
`zig-out/smoke-7d91c0c8834c4c7ea89e4a7b5a3401ce.serial.log` passou com
`RADV F device count: 0x00000001` e repetiu o marcador final. O QEMU foi
encerrado. A enumeração DRM e seu caminho sysfs da stack real estão validados;
dispositivo Vulkan, filas, command submission e triângulo continuam dependendo
de uma Radeon física suportada.

O probe agora também prepara o próximo gate físico sem fingir que o QEMU o
validou: se `vkEnumeratePhysicalDevices` retornar uma GPU, ele materializa o
`VkPhysicalDevice`, procura uma família com `VK_QUEUE_GRAPHICS_BIT`, chama
`vkCreateDevice`, resolve `vkGetDeviceQueue` por `vkGetDeviceProcAddr`, exige
uma fila válida e destrói o dispositivo. Somente então imprime
`RADV logical device and graphics queue ready`. O ramo compila e o caminho
headless sem GPU continua passando em
`zig-out/smoke-a0a5551d20294b4db03235caf4488094.serial.log`, mas criação de
device/fila permanece não validada até executar em Radeon real.

Após o gate de device/fila, o mesmo probe agora resolve as entradas Vulkan de
dispositivo, cria command pool e command buffer primário, grava/finaliza uma
submissão vazia one-shot, cria um fence, chama `vkQueueSubmit` e exige
`vkWaitForFences` antes de destruir os recursos. O marcador separado
`RADV command submission and fence ready` só aparece após conclusão física da
fila. O ramo compilou com a stack RADV real; a suíte passou 12/12 e o caminho
QEMU sem dispositivo repetiu `RADV dynamic loader ready` em
`zig-out/smoke-fc0f959d3d3448bdb762366cdfd1987f.serial.log`. Esse resultado não
executa nem valida o novo ramo: command submission/fence continuam pendentes de
Radeon real.

Os shaders mínimos do próximo triângulo também são reproduzíveis: vertex shader
por `gl_VertexIndex` e fragment shader azul foram adicionados em GLSL 450.
`tools/build-radv-shaders.ps1` verifica o glslang 16.5.0 fixado, gera SPIR-V
Vulkan 1.0, valida magic/alinhamento e produz arrays C. SHA-256 atuais: vertex
`88f975d1101600ceb47e860c2ffab90a055648b745fb2b98fdcb988d3deb8de5` e
fragment `e8348eb98ba3f8f6449a8f612442b5773c4d5ab139171271d4ab9c6d1e2d499d`.
O ramo físico cria e destrói ambos os `VkShaderModule` e só então emite
`RADV triangle shader modules ready`; o build audita a presença desse gate.
Compilação, 12/12 testes e o caminho QEMU headless passaram em
`zig-out/smoke-4eb29f9004ca41e58a23eba0ddad6278.serial.log`. A criação dos
shader modules ainda requer validação real, e não equivale a pipeline/draw.

O ramo físico também monta o estado imutável do primeiro draw: render pass
offscreen `R8G8B8A8_UNORM`, subpass gráfico, pipeline layout vazio, estágios
vertex/fragment, triangle list, viewport/scissor 64×64, rasterização fill sem
culling, uma amostra e escrita RGBA. Ele chama `vkCreateGraphicsPipelines` e
emite `RADV triangle graphics pipeline ready` somente após obter um pipeline
válido, destruindo pipeline, layout, render pass e shaders na ordem inversa. O
build e o verificador de hardware exigem esse marcador. A implementação
compilou; 12/12 testes e o caminho QEMU headless passaram em
`zig-out/smoke-b0617dc8c9804569882a1f420b50779b.serial.log`. O ramo de pipeline
não executou no QEMU e permanece pendente de Radeon. O estágio seguinte de
imagem/memória/framebuffer foi preparado conforme registrado abaixo.

Imagem/memória/framebuffer offscreen também estão preparados no ramo físico. O
probe cria uma imagem 2D RGBA8 64×64 com uso color-attachment/transfer-source,
consulta requisitos, escolhe memory type device-local compatível (com fallback
compatível), aloca e faz bind, cria image view e framebuffer para o render pass.
O marcador `RADV triangle offscreen framebuffer ready` só aparece após todos os
handles serem válidos; a limpeza destrói framebuffer/view/image antes de liberar
a memória. Build e verificador físico exigem o marcador. Compilação, 12/12
testes, fixture do contrato e o caminho headless passaram em
`zig-out/smoke-0a64edfdf9f848ef9381f8bb35401398.serial.log`. Essas operações não
executaram no QEMU. O draw foi preparado no incremento seguinte; readback e
verificação de pixels continuam pendentes.

O draw offscreen foi conectado ao mesmo tempo de vida dos recursos: o probe
cria command pool/buffer, inicia o render pass com clear preto, liga o graphics
pipeline, grava `vkCmdDraw(3, 1, 0, 0)`, encerra o render pass e command buffer,
submete com fence e aguarda conclusão antes de destruir framebuffer/imagem. Só
depois emite `RADV offscreen triangle draw ready`; build e verificador físico
exigem o marcador. A implementação compilou, 12/12 testes e o contrato de log
passaram, e o caminho QEMU sem GPU permaneceu estável em
`zig-out/smoke-c29771911c49440b90b7b60bce31f544.serial.log`. O ramo draw não
executou no QEMU: faltam validação em Radeon, cópia/readback e comprovação dos
pixels antes de chamar isso de triângulo validado; apresentação em display vem
depois do offscreen comprovado.

O backing de readback também está preparado: o probe cria buffer de 16 KiB com
`VK_BUFFER_USAGE_TRANSFER_DST_BIT`, consulta requisitos, seleciona memória
host-visible preferindo host-coherent, aloca e faz bind, mantendo buffer/memória
vivos até depois do draw/fence. A imagem termina o render pass em
`VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL`. O marcador
`RADV triangle readback buffer ready` só aparece após o bind e integra build e
verificador físico. Compilação, 12/12 testes, fixture e o caminho QEMU headless
passaram em `zig-out/smoke-4493b62367034960a666d9a7c69ebfed.serial.log`.
O QEMU foi encerrado. A cópia e verificação foram preparadas no incremento
seguinte e ainda precisam executar em Radeon real.

O gate offscreen agora fecha o ciclo de evidência: após `vkCmdDraw`, o command
buffer grava `vkCmdCopyImageToBuffer` usando o layout final transfer-source,
submete e aguarda o fence. Em seguida mapeia os 16 KiB, chama
`vkInvalidateMappedMemoryRanges` quando o memory type não é host-coherent e
verifica RGBA do canto preto e do centro azul com tolerâncias explícitas. Apenas
após os dois pixels passarem emite `RADV offscreen triangle pixels verified`.
Build, fixture e verificador físico exigem esse marcador. A implementação
compilou, 12/12 testes e o caminho QEMU headless passaram em
`zig-out/smoke-86128ce6f6d24b4e8b7d40640beb3ad0.serial.log`; QEMU encerrado. O
render pass inclui dependência explícita de saída para transferência,
`COLOR_ATTACHMENT_OUTPUT/COLOR_ATTACHMENT_WRITE` →
`TRANSFER/TRANSFER_READ`, garantindo visibilidade antes do copy em vez de
depender apenas da transição de layout.
O ramo de pixels não executou sem Radeon, portanto o primeiro triângulo AMD
continua não validado até esse marcador surgir em hardware real suportado.

A validação de pixels deixou de depender apenas de duas amostras: percorre os
4.096 pixels, classifica fundo preto, fragmentos azuis e valores inesperados,
registra as contagens `RADV B`/`RADV K`. Um cálculo por centros de pixel para as
posições do vertex shader prevê 722 fragmentos. O gate exige 680–760 azuis,
pelo menos 3.300 pretos e no máximo 16 inesperados, além das amostras de canto e
centro; o verificador exige que azul+preto cubram ao menos 4.080 pixels. O
fixture usa a referência 722/3.374 e passou; build, 12/12 testes e o caminho
headless
passaram em `zig-out/smoke-7020b09d965741a7bf7712c9e50bfa23.serial.log`. O
QEMU foi encerrado e não fornece evidência do ramo físico.

`tools/verify-radv-hardware-log.ps1` formaliza a evidência desse degrau físico:
ele exige vendor AMD `0x1002`, PCI device informado pelo operador, contagem
Vulkan não zero e os marcadores de device/fila e submission/fence. O log QEMU
foi rejeitado por vendor `0x1234`. Um fixture explicitamente marcado testa o
parser somente com `-AllowFixture` e é recusado no modo normal, impedindo que
seja apresentado como evidência física. O verificador integra
`tools/test-system.ps1`; a suíte passou 12/12 e os dois boots limitados até o
console. Isso prepara uma validação reproduzível, mas não substitui o futuro log
de uma Radeon real nem o gate separado de triângulo/apresentação.

O gate foi consolidado em `tools/test-radv-runtime.ps1`: ele recompila o probe,
executa o boot tardio com prazo, exige `RADV dynamic loader ready` e encerra
qualquer processo QEMU criado pela própria execução mesmo em caso de falha. A
execução reproduzível passou em
`zig-out/smoke-52b5d4443e8e409781a22457b2adfa85.serial.log`. A suíte geral
`tools/test-system.ps1` também passou os testes de host e ambos os boots
limitados até o console após a correção de ponteiros de DSO. A tabela compacta
agora cobre todos os mappings iniciais — executável, TLS, DSOs, intérprete,
stack e arenas — enquanto as regiões comuns permanecem no caminho rápido. O
módulo `kernel/user_regions.zig` testa limites exatos, lacunas, travessia de
segmento, tamanho excessivo e overflow. A própria construção dos intervalos
agora usa o módulo testado e cobre compactação adjacente, ordem não adjacente,
capacidade e regiões inválidas; a suíte passou 12/12. O boot RADV limitado
repetiu descoberta completa e o marcador final em
`zig-out/smoke-c67a6f4be4e44fb5bcd184d07f43e90d.serial.log`. QEMU encerrado.

`-Dradv-probe-after-gpu=true` agora permite executar o mesmo probe e seus
gates após a preparação gráfica, sem habilitar automaticamente gates MMIO.
Isso evita enumerar prematuramente a Radeon no futuro teste físico. O caminho
tardio passou em QEMU no log
`zig-out/smoke-8c713689f7994df0b47e618920eeb07b.serial.log`, incluindo
instância, enumeração e recuperação de páginas. O runner encerrou o QEMU.

O probe agora executa `vkEnumeratePhysicalDevices` e registra a contagem
retornada. A enumeração e o gate final passaram no boot limitado registrado em
`zig-out/smoke-0c5bb9c212584237b9ff488d5b423533.serial.log`, com criação e
destruição da instância e recuperação de páginas. Essa execução em QEMU não
substitui a descoberta de uma Radeon física nem valida criação de dispositivo,
filas ou triângulo. O QEMU foi encerrado automaticamente.

Integração de inicialização musl validada: o loader encontra
`csos_musl_bootstrap` na libc e transmite por auxv privado os descritores
PT_TLS com a numeração DTPMOD64 preservada. O intérprete chama o bootstrap
antes dos construtores. O boot limitado passou em
`zig-out/smoke-cca7d71cbfc446b2a9d8c59ec7751334.serial.log`: cookie do
construtor, negociação ICD, `vkCreateInstance` e `vkDestroyInstance` tiveram
sucesso, assim como o gate de recuperação de páginas. Isso comprova criação
de instância headless no QEMU; enumeração/dispositivo Radeon, filas reais e
triângulos AMD/NVIDIA permanecem pendentes. O QEMU foi encerrado.

Foi compilada a entrada privada `csos_musl_bootstrap` em
`tools/musl-csos-bootstrap.c`, ligada à musl com seus headers internos fixados.
Ela valida descritores TLS limitados, preserva slots DTPMOD64, prepara a lista
TLS e usa `__copy_tls`, `__init_tp` e `__init_libc` oficiais. O link auditado
produziu 3.512.720 bytes e exportou essa entrada. Ainda não está conectada ao
intérprete nem foi executada em Ring 3; o staging foi preservado. Próximo passo:
transmitir descritores de PT_TLS e a entrada pelo contrato do loader, invocá-la
antes dos construtores e validar retorno, TLS e recuperação de páginas.

Recompilação limpa concluída: 1.347/1.347 objetos upstream foram recompilados,
o relink passou na auditoria e a libc de 3.509.112 bytes foi instalada no
staging. SHA-256:
`8c275c3e6dfd669b1574c4dd413be3fa20c7ac2fee9350734cf084e00a282604`.
O checkout musl permanece limpo. Isso elimina a dependência dos experimentos
de edição de visibilidade. O novo runtime ainda precisa repetir a validação
Ring 3 após a integração de auxv/thread pointer/DTV antes dos construtores.

O script `build-musl-runtime.ps1` exige o checkout musl fixado e limpo,
recompila os objetos upstream, executa link/auditoria e copia para staging
somente após sucesso. A preparação manual deixou de ser necessária:
`tools/configure-musl-runtime.ps1` cria deterministicamente o build out-of-tree
com o Zig fixado, target `x86_64-linux-musl` e `-O2 -fPIC`, e é chamado
automaticamente quando `config.mak` não existe. Uma configuração limpa em
diretório temporário passou por todas as sondagens upstream e gerou `config.mak`
com arquitetura, compilador, AR, RANLIB e flags esperados. O relink completo
continua protegido pela auditoria existente antes do staging. O build agora
também audita configurações já existentes e rejeita arquitetura, fonte,
toolchain, PIC ou `syslibdir` divergentes, normalizando `srcdir` relativo e
absoluto. O fluxo completo recompilou 1.347/1.347 objetos, passou link e
auditoria e instalou uma libc de 3.512.720 bytes, SHA-256
`5320b8fe4ecf19fead23016a302e17ca47c54b4bf91cc3ceb8b74a9ddb8cb47d`.
O boot limitado com essa libc passou bootstrap TLS, construtores, descoberta
libdrm completa, criação da instância Vulkan e `RADV dynamic loader ready` em
`zig-out/smoke-da92a31b3f2e444185df314fa8b94bad.serial.log`. O QEMU foi
encerrado.

`audit-musl-runtime.py` agora integra o link da musl e exige exports essenciais
apontando para bytes em segmentos executáveis, SONAME, ausência de dependências
externas/RPATH/TEXTREL e relocations suportadas. A auditoria aceitou o ELF real
anterior e rejeitou explicitamente a DSO de stubs em `strlen`. A recompilação
dos objetos upstream continua em andamento; falta auditar o novo relink.

A reprodução sem edição de símbolos está sendo feita por
`tools/rebuild-musl-objects.py`: ele extrai os comandos de compilação do Makefile
upstream e recompila todos os objetos, com paralelismo limitado. Os experimentos
`promote-musl-exports.py` e `musl-exports.map` foram removidos. A conclusão dessa
recompilação e o relink ainda precisam ser observados antes de declarar o build
limpo validado.

A leitura da musl upstream confirmou que `ldso/dynlink.c` fornece um
`__init_tls` vazio: o carregador musl normalmente prepara o thread pointer e
DTV antes de `__libc_start_main`. Assim, chamar esse entrypoint isoladamente
não inicializa corretamente o TLS no carregador CSOS. A integração deve
preparar o estado completo antes dos construtores, incluindo ambiente, auxv,
thread pointer e os módulos TLS carregados. O intérprete CSOS agora passa
`argc`, `argv` e `envp` aos construtores, e o probe verifica esse contrato.
`DT_INIT` não executável volta a ser rejeitado: a exceção temporária para os
stubs foi retirada. A validação Vulkan segue pendente da inicialização musl.

O `_start` C do probe tinha alinhamento SysV incorreto: o código emitia
`movaps` numa stack desalinhada por não existir endereço de retorno na entrada
ELF. Uma entrada assembly agora alinha RSP e chama `probe_main`. O boot avançou
até um page fault em `libc.so + 0x63c90`, identificado por addr2line como
`get_random_secret` em `mallocng/glue.h:47`, acesso ao endereço zero. Isso
direciona o próximo trabalho à inicialização da libc e de seu auxv antes de
malloc/Vulkan. Log: `zig-out/smoke-3fa6eea3cac645e79f04df6e1dab6031.serial.log`.
QEMU encerrado ao fim do prazo de 30 segundos; instância Vulkan ainda pendente.

O probe foi ampliado para resolver `vkCreateInstance` pelo ICD, criar uma
instância e chamar `vkDestroyInstance`, usando os headers Vulkan do Mesa fixado.
O build passou, mas o boot limitado de 30 segundos terminou em exceção de
proteção geral (marcador `G` do vetor 13), após o intérprete e antes do marcador
de sucesso. Log: `zig-out/smoke-477a716e5073490babe72d2e79f593a3.serial.log`.
O QEMU foi encerrado. Próximo diagnóstico: capturar RIP/estado da exceção e
verificar alinhamento da stack e inicialização libc/TLS nesse caminho. A criação
de instância continua não validada; o sucesso anterior cobre apenas negociação
e construtores.

Validação em 2026-09-05: a musl PIC de 3.509.208 bytes passou no probe RADV
em Ring 3 com os construtores habilitados. Uma segunda execução adicionou ao
executável um construtor que grava um cookie, verificado antes da negociação
do ICD; o marcador `RADV dynamic loader ready` passou novamente. Os gates
incluem carregamento de cinco objetos e recuperação das páginas. Ambos os
boots foram limitados e encerrados. Isso ainda não valida `vkCreateInstance`,
dispositivo Vulkan ou hardware AMD/NVIDIA. Permanecem a reprodução do build
sem as alterações experimentais de visibilidade e o avanço para criação de
instância Vulkan.

O link da musl PIC avançou: `link-musl-shared.py` compila `mulsc3`, `muldc3`
e `mulxc3` do compiler-rt fixado, exige sua revisão exata e incorpora os objetos
com visibilidade interna. Sem `-lgcc`/`-lgcc_eh`, o link concluiu e passou a
exportar `strlen` e `memcpy`, com SONAME `libc.so` e sem `DT_NEEDED` externo.
Esse novo artefato ainda precisa repetir o probe Ring 3 antes de ser considerado
runtime operacional. O problema de exports observado no link anterior foi
resolvido nessa combinação; as tentativas anteriores de editar visibilidade
dos objetos precisam ser removidas do fluxo reproduzível e revalidadas.

Atualização em 2026-09-05: musl v1.2.5 oficial foi obtida no commit
`0784374d561435f7c787a555aeab8ede699ed298` e seus objetos PIC foram compilados.
O link usa response file para respeitar o limite de comandos do Windows.
A inspeção da linha efetiva revelou que `-lgcc_eh` introduzia libunwind e a
libc de stubs do Zig. Sem essas dependências, faltam as rotinas compiler-rt
`__mulsc3`, `__muldc3` e `__mulxc3`; o runtime ainda não está validado.
O script antigo de staging foi desabilitado para não reinstalar os stubs.
Próximo passo: fornecer essas rotinas PIC, auditar exports públicos e só então
repetir o probe RADV limitado. A causa completa de `strlen` oculto permanece
em investigação; as tentativas de promover símbolos não provaram solução.

Regressão de recuperação Ring 3 corrigida: iterações por valor da tabela GPUVA
excediam a stack de syscalls de 64 KiB e corrompiam `drm_pages`. As iterações
agora usam referências; o pico instrumentado caiu de 170.504 para 11.920 bytes.
Os diagnósticos e as stacks experimentais foram removidos. `zig build test`
passou 10/10 testes; boot normal e `-Ddrm-amdgpu-abi-test=true` passaram sem
instrumentação, exigindo `CSOS M17 process reclaim ready` e igualdade de páginas.
Detalhes e logs em `docs/radv-bringup-audit.md`. Isso não comprova Vulkan real.

O alinhamento GEM de 2 MiB exigido pelo ring GFX11 foi implementado nos caminhos
VRAM e GTT. Testes de host cobrem allocator físico, GEM VRAM e, em Windows com
memória baixa, GEM GTT/fallback por VRAM esgotada. GEM GTT alinhado também passou
em Ring 3, assim como VRAM|GTT com fallback quando o backend VRAM está ausente.
Ainda faltam VRAM esgotada em Ring 3 e a alocação pelo RADV real, conforme
`docs/radv-bringup-audit.md`. Isso não equivale a execução da stack real.

O libdrm original já executa `drmGetVersion` e `drmGetDevice2` em Ring 3 e
identifica a GPU QEMU `1234:1111`, com recuperação de memória validada. Foram
corrigidos o comando ioctl estendido com sinal, hints de mmap e a stack de
userspace (128 KiB, distinta da stack de syscalls). Isso não valida AMDGPU/RADV.

O probe também passou após a preparação gráfica, até `CSOS graphical session ready`,
com recuperação de páginas. Essa validação corrigiu um acesso incondicional ao
IP discovery AMD no caminho QEMU. `-Dlibdrm-probe-after-gpu=true` seleciona o
ponto tardio sem habilitar gates MMIO; hardware AMD/NVIDIA real segue pendente.

Regressões adicionais comprovadas: render node reconhecido pelo libdrm original,
duplicação/flags de descritor e mmap GEM pelo render node. O teste AMDGPU exige
55 ioctls, quatro mmaps e cinco objetos liberados, incluindo rejeição de mmap
executável, privado e fora do BO. A validação consolidada está em
`tools/test-system.ps1`: testes de host e dois boots limitados até o console.
Ela não substitui libdrm_amdgpu/RADV operacional nem teste físico AMD/NVIDIA.

As três operações de mapeamento (`mmap`, `mprotect` e `munmap`) rejeitam
comprimentos que transbordariam o arredondamento para páginas. A regressão
Ring 3 verifica os erros e preserva leitura/escrita do BO após as rejeições de
proteção e unmap. A suíte consolidada passou novamente (10 testes de host e
dois boots até o console); isso é robustez da base do SO, não avanço de Vulkan.

O probe libdrm_amdgpu agora inclui, após inicialização bem-sucedida, alocação GTT
com alinhamento solicitado de 2 MiB, leitura/escrita CPU, reserva/mapeamento
GPUVA e liberação dos recursos pela biblioteca original. O build passou;
esse novo caminho ainda não executou em Radeon. QEMU continua sendo rejeitado
por DRM 1.0, sem simular hardware AMD para ultrapassar a inicialização.

A preparação da stack real também precisa validar o carregamento ELF: hoje o
loader só aceita `/lib/ld-csos.so` e até quatro objetos compartilhados. Os
probes estáticos não comprovam runtime dinâmico Linux. Antes de ampliar a ABI,
construir a stack escolhida e inventariar seus requisitos reais de intérprete,
bibliotecas e relocations. A syscall 204 vista no probe tem fallback na consulta
musl de CPUs e não é a causa da rejeição DRM observada.

O checkout Mesa completo da revisão auditada `9311c93dbef6b87a30bc282c3683efefc5f26f77`
agora está em `.tools/mesa-src`, sem alterações. As ferramentas Python de build
estão isoladas e fixadas em `tools/mesa-build-requirements.txt`. Configuração,
compilação Linux do RADV e inventário ELF continuam pendentes; obter os fontes
não conta como suporte gráfico funcional.

O perfil de cross-build em `tools/configure-radv.ps1` separa geradores Windows
de bibliotecas Linux x86-64 musl. A configuração reconheceu C/C++ de ambos os
targets e parou por ausência de `glslangValidator`, exigido pelo RADV dessa
revisão. Resolver essa ferramenta nativa é o próximo passo de build; libdrm
Linux e outras dependências ainda precisam ser configuradas. O perfil inicial
sem WSI/display não substitui o caminho final de apresentação Vulkan.

O requisito glslang foi resolvido com o release oficial 16.5.0, isolado em
`.tools` e verificado por SHA-256 via `tools/prepare-glslang.ps1`. Meson agora
encontra o compilador de shaders e para na descoberta de libdrm: falta
pkg-config para o target Linux e as bibliotecas target instaladas. O build
RADV continua pendente; nenhuma validação física foi substituída.

libdrm e libdrm_amdgpu 2.4.134 agora foram compilados como bibliotecas ELF64
x86-64 e instalados no staging Linux via `tools/build-libdrm-linux.ps1`.
pkgconf nativo encontra ambos com versão e caminhos corretos. Os SONAMEs são
`libdrm.so.2` e `libdrm_amdgpu.so.1`; ambos exigem `libc.so`. Isso ainda não
comprova carregamento no CSOS. Próxima etapa: repetir a configuração RADV com
essas dependências, sem usar o launcher Python defeituoso do pkg-config.

A nova configuração RADV já reconheceu libdrm e libdrm_amdgpu 2.4.134 no
staging e avançou às sondagens do compilador. Os testes upstream
`core-symbols-check` e `amdgpu-symbols-check` passaram (2/2) e agora fazem parte
do script de build libdrm. Configuração completa e compilação RADV ainda não
foram comprovadas.

zlib 1.3.1 upstream foi compilada com Zig para Linux x86-64 e instalada no
mesmo staging por `tools/build-zlib-linux.ps1`. O script opera em cópia gerada
porque o CMake upstream renomeia `zconf.h`, preserva o checkout fixado e exige
ELF no resultado. pkgconf retorna 1.3.1; SONAME `libz.so.1`, dependência
`libc.so`. A configuração RADV anterior terminou exatamente por ausência de
zlib; a repetição com zlib está em andamento e ainda não comprova build.

Com zlib presente, o perfil headless RADV configurou 99 targets e concluiu os
770 passos. `libvulkan_radeon.so` é ELF64 x86-64, tem SONAME correto, depende
somente de `libdrm_amdgpu.so.1`, `libz.so.1`, `libdrm.so.2` e `libc.so`, e
exporta apenas os três entrypoints ICD esperados. O wrapper preserva o version
script GNU e remove do ELF apenas o RUNPATH de staging Windows que o Meson
cross-host tentava inserir. A detecção AVX2 não foi desativada: o símbolo
`__cpu_model` veio do `cpu_model/x86.c` oficial do compiler-rt 21.1.0, compilado
como PIC pela revisão fixada `3623fe661ae35c6c80ac221f14d85be76aa870f1`.
Isto comprova o build real do driver, não seu carregamento no CSOS, command
submission em Radeon nem triângulo Vulkan físico; o progresso global permanece
em aproximadamente 40% concluído e 60% restante.

O primeiro inventário do ELF mostra que os tipos de relocation do RADV já são
os quatro tratados pelo loader (`RELATIVE`, `JUMP_SLOT`, `GLOB_DAT` e
`DTPMOD64`). O bloqueio imediato é capacidade: os quatro segmentos LOAD do
driver ocupam 4.423 páginas, contra `max_mappings = 512`, e as tabelas atuais
ficam na stack. A correção deve mover o bookkeeping para armazenamento escalável
e contabilizar também libdrm, zlib e libc; apenas aumentar o array local não é
aceitável. Depois ainda será necessário carregar dependências reais do
filesystem e executar `DT_INIT_ARRAY` antes de tentar iniciar o ICD.

O limite imediato de mappings foi removido sem ampliar a stack: o workspace
serializado do loader agora mantém 8.192 mappings e ranges de propriedade em
BSS, deixando espaço para o RADV e suas dependências diretas. Isso deverá virar
estado por processo quando houver `exec` concorrente. A suíte consolidada passou
10/10 testes de host e os dois boots QEMU limitados até o console; ambos foram
encerrados automaticamente. O teste ainda não carrega o RADV e não altera a
estimativa global de 40%/60%.

O inventário agora é um gate automático de `build-radv.ps1`: arquitetura,
SONAME, NEEDED, exports, ausência de RUNPATH, runtime de CPU, relocations e
capacidade LOAD são verificados após cada build. Mesmo sem debug, o driver mede
19.084.448 bytes, acima do limite atual de 16 MiB por `.so`; strip completo
chega a 18.003.024 bytes. Portanto o próximo loader não pode depender de ler o
arquivo inteiro numa alocação contígua, e o filesystem precisa aceitar os nomes
Linux reais além do FAT 8.3 atual.

`build-radv.ps1` agora gera e audita também o runtime stripado em
`zig-out/mesa-sysroot/usr/lib/libvulkan_radeon.so` (18.003.024 bytes), mantendo
o ELF completo separado para diagnóstico. O teto defensivo por objeto do loader
subiu para 32 MiB e o pacote cabe nele. Isso remove a rejeição artificial por
tamanho; a alocação contígua duplicada ainda deve ser substituída por leitura
segmentada, enquanto instalação e nomes foram cobertos no incremento seguinte.

O VFS agora expõe os cinco nomes Linux canônicos do runtime e os traduz para
aliases FAT 8.3 internos, sem mudar os SONAMEs. A imagem opcional aceita RADV,
libdrm_amdgpu, libdrm, zlib e musl libc, e um boot confirmou o magic ELF de
todos por `/usr/lib/...`. O probe dinâmico mínimo carregou o RADV real e as
quatro dependências no CSOS, aplicou relocations, configurou TLS e chamou
`vk_icdNegotiateLoaderICDInterfaceVersion`; cinco objetos novos e recuperação
integral das páginas são gates do marcador `RADV dynamic loader ready`.
Isso comprova carregamento da stack real, mas ainda não executa a criação de
instância/dispositivo Vulkan, construtores gerais nem hardware Radeon.

O loader agora coleta `DT_INIT` e `DT_INIT_ARRAY` somente depois de aplicar
todas as relocations, ordena dependências antes dos consumidores e entrega a
lista ao intérprete Ring 3 por auxv privado. Testes de host continuam passando.
A primeira execução dos construtores revelou que a `libc.so` anteriormente
materializada pelo Zig é apenas uma DSO de símbolos/stubs: suas funções apontam
para uma `.text` de tamanho zero fora de `PT_LOAD`. O `DT_INIT` sentinela foi
tratado sem enfraquecer a validação dos construtores reais, mas
`__cpu_indicator_init` do RADV confirmou o mesmo defeito ao chamar libc. Dois
boots QEMU limitados reproduziram o fault em `libc.so + 0x15360` e foram
encerrados automaticamente. A musl 1.2.5 compartilhada real, compilada com PIC
a partir das fontes e auditada, agora substitui a DSO de stubs; bootstrap TLS,
construtores do RADV e descoberta DRM/KMS passam no boot limitado. O backend
Vulkan do dispositivo ainda não aparece no QEMU (device count zero), portanto
instância, filas e command submission continuam aguardando Radeon física.

1. Inventariar e implementar no loader/ABI do CSOS os requisitos restantes observados pelo `libvulkan_radeon.so` até executar libdrm_amdgpu/RADV real e validar command submission no caminho AMD GFX11 em hardware real.
2. Validar o primeiro triângulo AMD/RADV em Radeon real suportada.
3. Tornar NVIDIA a frente ativa de M14: adaptar a infraestrutura compartilhada e validar Nouveau/NVK ou stack compatível em uma máquina somente com GeForce suportada, incluindo inicialização, display, memória, filas, sincronização e triângulo Vulkan.
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
