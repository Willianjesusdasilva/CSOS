# Auditoria de bring-up RADV

## Fontes verificadas

- Mesa `9311c93dbef6b87a30bc282c3683efefc5f26f77`.
- libdrm `773536b1e5dde694dd743815528aff8bb2cf2cc3`.
- CSOS após `c2a5471`.

Esta auditoria é de código, não execução de Mesa no CSOS nem prova de GPU real.

## Alinhamento do ring GFX11

Em `src/amd/vulkan/radv_queue.c`, `radv_update_preamble_cs` aloca os
`ge_rings_bo` de GFX11 com alinhamento de **2 MiB**, domínio VRAM e flags
`32BIT | DISCARDABLE`. O tamanho vem de
`total_attribute_pos_prim_ring_size`. O winsys, em `radv_amdgpu_bo.c`, transfere
o alinhamento para `request.phys_alignment`; o libdrm, em `amdgpu_bo.c`, o copia
para `drm_amdgpu_gem_create.in.alignment`.

Antes da correção, `kernel/syscalls.zig:amdgpuGemCreate` rejeitava alinhamento maior que
4096 antes de consultar o allocator VRAM. Portanto essa alocação retorna
`EINVAL` mesmo com firmware, GART e CP operacionais. Isso bloqueia a preparação
da fila gráfica; não é apenas uma otimização opcional.

O allocator `AmdVramAllocator.allocatePinned` já aceita potências de dois
maiores que uma página e alinha o endereço MC. O allocator físico usado no
caminho GTT agora oferece `allocateAligned`: preserva prefixo e sufixo livres,
mantém a lista ordenada e rejeita overflow antes de mutar o estado. GEM usa o
alinhamento normalizado (no mínimo uma página) tanto na VRAM quanto no GTT,
incluindo fallback VRAM/GTT, e o preserva no BO para GEM_OP.

Testes de host verificam o allocator físico com alinhamento de 2 MiB, split e
merge dos fragmentos, accounting, falta de espaço e overflow. O handler GEM
real é testado com VRAM sintética: endereço MC de 2 MiB, GEM_OP, falta de um
segundo slot alinhado, liberação e normalização de 64 bytes para uma página.
Ainda falta executar o caminho GEM GTT/fallback completo em Ring 3 e a
alocação do ring pelo RADV real; os testes de allocator não substituem isso.

### Critérios de verificação

1. Acrescentar alocação física alinhada com preservação dos fragmentos livres,
   accounting e liberação corretos; não desperdiçar silenciosamente o padding.
2. Normalizar alinhamentos menores que uma página para 4096 e aceitar potências
   de dois maiores, com checagem de overflow antes de qualquer mutação.
3. Passar o alinhamento normalizado aos allocators VRAM e GTT e preservá-lo no BO.
4. Testar a requisição GFX11 de 2 MiB no handler GEM real, verificando endereço
   MC alinhado, GEM_OP, falha por falta de espaço e liberação da reserva.
5. Testar também GTT e fallback VRAM/GTT para não anunciar alinhamento falso.

## Gate de aceleração

`amdgpu_device_initialize` aborta se `AMDGPU_INFO_ACCEL_WORKING` for zero.
O CSOS agora consulta a saúde do backend físico após o teste PM4, em vez de
exigir Vulkan validado antes de permitir a inicialização do próprio RADV.
Essa correção possui testes de host; ativação física e execução libdrm/RADV
continuam pendentes.

## Limite da conclusão

Resolver o alinhamento não comprova que todas as dependências do RADV estejam
implementadas. Ainda é necessário construir e executar a stack real, observar
as próximas falhas e validar um triângulo em Radeon suportada. NVIDIA continua
obrigatória depois desse primeiro caminho AMD; Steam/CS2 permanecem no final.
