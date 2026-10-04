<a id="amisad-poc----guest-vm-hostnames-and-usernames"></a>

# AmisAd POC -- nomes de hospedeiro e de usuário das VMs convidadas

As VMs convidadas seguem a topologia do projeto ([plan/design/01-overview.md](../../../plan/design/01-overview.md)).
O **nome de hospedeiro** de cada VM é definido pela variável de sequência
`hostname` do Yuruna (propagada pela cadeia até o provisionamento, como
`username`), e sua conta inicial de **administrador** é `<hostname>-admin`.
As contas das personas da demonstração são adicionadas como
**não administradoras** (`adduser`, sem sudo) na VM que hospeda seus cenários.

**Preparação do cofre (obrigatória uma vez por nome de usuário).** As senhas
geradas automaticamente pelo cofre podem conter caracteres (`@`, `^`, ...)
que a digitação pela interface gráfica insere incorretamente no primeiro
login. Antes da primeira execução a partir do estado inicial, prepare cada
nome de usuário com uma senha segura para digitação (letras e dígitos),
a partir da raiz do checkout do Yuruna em `pwsh`:

```powershell
Import-Module ./test/extension/authentication/default.psm1
Set-Password -Username <name> -NewPassword '<alphanumeric>'
```

<a id="vms-and-administrators"></a>

## VMs e administradores

| VM / nome de hospedeiro | Nó do projeto | Administrador | Função |
|---------------|-------------|---------------|----------|
| `amisad-build` | máquina de compilação (infraestrutura do laboratório) | `amisad-build-admin` | Apenas a cadeia de ferramentas do Rust; compila o workspace e envia o arquivo tarball dos binários ao serviço stash. É parada após a etapa de compilação. |
| `amisad-core` | **vm-core** | `amisad-core-admin` | Kubernetes + PostgreSQL + NATS + os dez serviços implantados. Os cenários são executados aqui por SSH; cada um restaura o snapshot `amisad-core` para redefinir seu estado. |
| `amisad-edge-a` | **vm-edge-a** (região A) | `amisad-edge-a-admin` | VM slice sem estado; `slice-runtime` é entregue a cada execução de cenário por SSH a partir de vm-core. Permanece em execução durante os cenários e as demonstrações. |
| `amisad-edge-b` | **vm-edge-b** (região B) | `amisad-edge-b-admin` | Igual, na região B; permanece em execução durante os cenários e as demonstrações desde `s004.failover` (o cenário de soberania precisa de uma região mais espaçosa e não conforme para excluir). |

O snapshot intermediário `amisad-core-k8s` é transitório (consumido pela
renomeação da camada de implantação). Os administradores recebem sudo sem
senha e a chave SSH do executor durante o provisionamento; após o único
primeiro login de `start.guest` guiado por OCR, tudo é executado por SSH.

<a id="demo-users-non-administrators-on-amisad-core"></a>

## Usuários da demonstração (não administradores, em `amisad-core`)

| Nome de usuário | Persona | Finalidade |
|----------|---------|---------|
| `maya` | Maya, a compradora | Persona de login por console/SSH para a narrativa da demonstração; as etapas de API (`curl`) funcionam a partir de sua conta. O próprio `buyer-client` é executado pela conta de administrador (os binários ficam no diretório pessoal do administrador, com modo 0750). |
| `elena` | Elena, a vendedora | Persona de login por console/SSH para a narrativa da vendedora; as etapas `curl` do quadro de pedidos funcionam a partir de sua conta. |
| `tom` | Tom, o operador da transportadora/dos recursos | Narrativa de s004.failover: política de alocação, fila de incidentes, escalonamento; as etapas `curl` de resource-svc funcionam a partir de sua conta. |
| `priya` | Priya, a operadora da plataforma | Narrativa de s004.failover + s007.inventory: caso de incidente entre participantes; verificação do cadastro de participantes. |
| `marcel` | Marcel, a agência de publicidade | Narrativa de s005.attribution: campanha, briefing criativo, relatório de atribuição; as etapas `curl` de ads-svc funcionam a partir de sua conta. |
| `kai` | Kai, o criativo | Narrativa de s005.attribution: aceita o briefing, produz o material, visualiza o desempenho. |
| `pat` | Pat, o delegado | Narrativa de s006.mandate: atua sob o mandato de escopo limitado de Maya no workspace do delegado. |
| `alex` | Alex, o parceiro de integração | Narrativa de s007.inventory: cria e certifica o conector; as etapas `curl` de connect-svc funcionam a partir de sua conta. |
| `sam` | Sam, o agente de suporte | Narrativa de s008.mediation: trabalha no caso de suporte com os metadados; solicita a divulgação de escopo limitado. |
| `dana` | Dana, a analista de demanda | Narrativa de s009.suppression: consulta a bancada de insights, publica a previsão de demanda. |
| `ingrid` | Ingrid, a auditora de confiança | Narrativa de s010.certification: executa a certificação independente em audit-svc. |

Todos os onze são criados pela cadeia de implantação de vm-core
(`adduser --disabled-password`, seguido de um `chpasswd` com valores
obtidos do cofre em uma etapa `sensitive: true`) e **não** estão no sudoers.

<a id="service-accounts-not-login-users"></a>

## Contas de serviço (não são usuários de login)

| Conta | Local | Finalidade |
|---------|-------|---------|
| `amisad` | Papel do PostgreSQL em `amisad-core` | Papel da aplicação para ledger-svc e seller-svc (`DATABASE_URL`). Apenas INSERT+SELECT nas tabelas do ledger -- o banco impõe a restrição de somente acréscimo. Senha fixa do laboratório `amisadpoc2026` (dentro de uma URL, portanto alfanumérica); não é gerenciada pelo cofre e é provisionada pela etapa db. |
| `amisad_audit_ro` | Papel do PostgreSQL (NOLOGIN) | Acesso somente de leitura ao ledger, reservado para audit-svc; a independência é arquitetural. |

<a id="core-edge-access"></a>

## Acesso do núcleo às bordas

Os scripts de cenário em vm-core acessam as VMs de borda com um **par de
chaves da demonstração** dedicado (`~/.ssh/amisad-demo-key` no diretório
pessoal de `amisad-core-admin`). O par é gerado **dentro de vm-core**
pela etapa de usuários da cadeia de implantação (ed25519, sem frase-senha;
uma chave que já pode ser interpretada é mantida), e **a chave privada
nunca sai dessa VM**. Quando ambas as bordas estão em execução, o controlador
do laboratório (`test/Initialize-Lab.ps1`, etapa 6;
`poc/build/run-tests.ps1`, etapa 4b) lê a metade *pública* em vm-core
e a grava no `authorized_keys` de cada borda, ambas as ações pelo canal
SSH do executor -- o mesmo usado por todas as outras ações do hospedeiro
para o convidado -- e então comprova o login a partir de vm-core. Cada borda
mantém exatamente uma entrada terminada em `amisad-demo`: uma nova execução
a substitui em vez de acrescentar outra, de modo que a rotação da chave
invalida a anterior. As bordas não podem receber a chave durante o
provisionamento, pois são criadas antes de vm-core existir.

**Por que o serviço de status não é o canal.** O serviço de status responde a
qualquer máquina que alcance sua porta, portanto um arquivo servido por ele
pode ser lido por toda a LAN: um projeto que coloca a chave privada onde os
convidados podem baixá-la publica essa chave, e uma LAN de laboratório
considerada confiável não limita quem pode ler um arquivo servido. Por isso,
nada aqui cria, copia ou serve uma chave privada sob um diretório servido pelo
serviço de status (`test/status`, suas montagens `runtime/` e `log/`, ou o
checkout servido como `yuruna-repo/`), e o listener do framework também
recusa nomes de arquivos de chave privada, onde quer que estejam. A chave
pública não é secreta e trafega por SSH. Os relatórios de IP das bordas
(`<hostname>.ip.txt` em `log/handoff/` do servidor de status, usados
por vm-core para localizar as bordas sem DNS) também não são secretos e
trafegam por essa rota.

**Rotação (operador).** Um hospedeiro que executou uma versão anterior deste
laboratório gerou o par em `test/status/handoff/` e fez os convidados
baixarem ambas as metades pelo serviço de status, portanto pode ter servido
a chave privada para a LAN: trate-a como exposta. `Initialize-Lab.ps1`
e `run-tests.ps1` excluem `test/status/handoff/amisad-demo-key` e seu
`.pub` quando os encontram e informam a exclusão; toda VM criada a partir
de então confia em uma chave nova. Uma VM persistente criada antes ainda
confia na antiga: reconstrua-a ou remova a linha de `authorized_keys`
terminada em `amisad-demo`
(`sed -i '/ amisad-demo$/d' ~/.ssh/authorized_keys`) e deixe o controlador
adicionar a nova. Reinicie também o serviço de status do hospedeiro, para
que não permaneça em execução um listener iniciado antes de o framework
passar a recusar nomes de chaves.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
