<a id="amisad-poc----test-automation"></a>

# AmisAd POC -- automação de testes

Automação completa a partir de uma **máquina limpa** (sem VMs pré-compiladas): monte a
topologia do projeto e execute, em ordem, cada cenário implementado nessa topologia. Para executar
a demonstração manualmente, veja [demo.md](../../../poc/demo.md).

<a id="native-service-contract-checks"></a>

## Verificações nativas dos contratos dos serviços

Na pasta `poc/`, execute `cargo build --workspace --locked`,
`cargo test --workspace --locked`, `python3 test/check_messages.py` e
`python3 test/service_contracts.py -v`. Defina `AMISAD_BIN_DIR` quando os binários
estiverem fora de `target/debug`. Os testes iniciam processos isolados em loopback e implementações de teste;
o caso de prazo limite leva cerca de 20 segundos. Eles não precisam de VM nem de commit temporário.

Para verificar a recuperação persistente, inicialize um **banco de dados PostgreSQL vazio e descartável**
com `db/schema.sql`, defina `AMISAD_TEST_DATABASE_URL` com sua URL de conexão e execute
`python3 test/service_contracts.py DurableContracts -v`. Essa suíte explícita grava
ofertas, instruções, pedidos e reembolsos de teste e depois reinicia os serviços.
Use um banco de dados novo em cada execução; nunca aponte para o banco de dados da demonstração.
A suíte comum usa armazenamento em memória, independentemente de `DATABASE_URL` definido pelo chamador.

Essas verificações complementam os cenários de VM abaixo. Elas não qualificam Kubernetes,
os arquivos de execução do Bazel nem a cadeia de ferramentas das imagens de contêiner com versões fixadas.

<a id="one-time-setup"></a>

## Configuração inicial

1. **Obtenha o framework.** Use o comando de uma linha para seu sistema operacional no
   `install/README.md` do repositório Yuruna (Remote one-liners) -- ele instala as dependências e
   clona o framework em `~/git/yuruna` (`%USERPROFILE%\git\yuruna` no
   Windows).

2. **Aponte o Yuruna para o AmisAd.** Na pasta `yuruna`:

   ```powershell
   Copy-Item test/test.config.yml.template test/test.config.yml
   ```

   Edite `test/test.config.yml`:
   - `repositories.projectUrl`: `https://github.com/alius-git/amisad.dev.git`
     (ou o caminho de um clone local) -- as sequências são descobertas em `poc/test/`.
   - `repositories.ghToken`: um PAT do GitHub com acesso de leitura (clone no hospedeiro).
   - `guestSequence`: reduza a lista para `- guest.ubuntu.server.24`.

3. **Preencha o cofre.** Na pasta `yuruna`, em `pwsh`:

   ```powershell
   Import-Module ./test/extension/authentication/default.psm1
   # Guest PAT for the production clone path (lab mode does not use it):
   Set-UserVaultKey -LogicalUser amisad-pat -VaultKey amisad-pat
   Set-Password -Username amisad-pat -NewPassword '<the PAT>'
   # One keystroke-safe (alphanumeric) password per username -- see usernames.md:
   Set-Password -Username amisad-build-admin  -NewPassword '<alnum>'
   Set-Password -Username amisad-core-admin   -NewPassword '<alnum>'
   Set-Password -Username amisad-edge-a-admin -NewPassword '<alnum>'
   Set-Password -Username amisad-edge-b-admin -NewPassword '<alnum>'
   Set-Password -Username maya  -NewPassword '<alnum>'
   Set-Password -Username elena -NewPassword '<alnum>'
   Set-Password -Username tom   -NewPassword '<alnum>'
   Set-Password -Username priya -NewPassword '<alnum>'
   Set-Password -Username marcel -NewPassword '<alnum>'
   Set-Password -Username kai    -NewPassword '<alnum>'
   Set-Password -Username pat    -NewPassword '<alnum>'
   Set-Password -Username alex   -NewPassword '<alnum>'
   Set-Password -Username sam    -NewPassword '<alnum>'
   Set-Password -Username dana   -NewPassword '<alnum>'
   Set-Password -Username ingrid -NewPassword '<alnum>'
   ```

   O cofre é um arquivo local ignorado pelo Git. Cadastre cada novo nome de usuário antes de sua
   primeira execução do zero ([usernames.md](usernames.md) explica o motivo).

4. **Disponibilize um stash service.** `amisad-build` envia seus binários para ele e
   `amisad-core` os baixa; sem esse serviço, a execução não tem nada para implantar.
   Este projeto não fornece **nenhum endereço de stash** -- o endereço do stash de um laboratório pertence
   a esse laboratório, e um endereço literal aqui ficaria desatualizado assim que o serviço fosse movido.
   Qualquer uma destas opções é suficiente:

   - execute um neste hospedeiro: `test/service/Start-StashServiceVM.ps1`, na pasta `yuruna`;
   - entre em um grupo que execute um -- o serviço se anuncia ao
     pool-aggregator e este hospedeiro obtém o endereço de volta (não há nada para
     configurar além do caching-proxy-service que este hospedeiro já usa);
   - informe-o: `$env:YURUNA_STASH_SERVICE_HOST = '<address>'` ou
     `pwsh test/Initialize-Lab.ps1 -StashServiceHost '<address>'`, neste
     repositório.

   O preflight consulta `/healthz` em cada candidato antes de iniciar qualquer etapa demorada,
   publica o endereço que respondeu para o restante do ciclo e
   **interrompe a execução imediatamente** quando nenhum responde -- ele nunca adivinha um endereço.

5. **Valide.** Execute `test/Test-Config.ps1` na pasta `yuruna`.

<a id="the-automation-model"></a>

## O modelo de automação

O orquestrador monta a topologia do projeto
([plan/design/01-overview.md](../../../plan/design/01-overview.md)) e executa todos os
cenários no mesmo `amisad-core` -- a restauração do
snapshot `amisad-core` no início de cada cenário **é** a redefinição de seu estado, mantendo
os cenários independentes sem VMs por cenário. Os nomes dos hospedeiros são definidos pela variável
`hostname` do framework; o administrador de cada VM é `<hostname>-admin`
([usernames.md](usernames.md)).

```
[0] cleanup        remove every amisad lab VM (current and legacy names)
                      and any leftover test-* VMs with their storage dirs;
                      delete a demo private key found in the status
                      service's served tree; resolve the
                      stash service (pinned or discovered), verify /healthz,
                      and publish the address -- no stash, no run.
[1] amisad-build   start.guest -> build tools -> snapshot; compile run
                      uploads amisad-<arch>-binaries.tgz to the stash service
                      and records its SHA-256 for the deploy to verify;
                      VM stopped afterwards.
[2] amisad-edge-a  start.guest -> IP reporter -> snapshot.
    amisad-edge-b  (provisioned one at a time: first-login OCR is only
                      reliable with no other lab VM running)
[3] amisad-core    start.guest -> k8s + PostgreSQL + NATS (snapshot
                      amisad-core-k8s) -> binaries from the stash, deploy
                      10 services (ledger+seller on PostgreSQL), add
                      maya/elena/tom/priya/marcel/kai/pat/alex/sam/dana/ingrid
                      and generate the core->edge demo keypair INSIDE this
                      VM -> snapshot amisad-core.
[4] both edges started; each reports its IP to the status service.
[4b] the PUBLIC half of amisad-core's demo key is written into both edges'
                      authorized_keys over the harness SSH channel, and
                      amisad-core's login to each is proved.
[5] scenarios in order, each: restore amisad-core -> drive over SSH
    (sshWaitReady + sshFetchAndExecute; no OCR, so live edge VMs cannot
    disturb it) -> full TVP asserts. slice-runtime runs on amisad-edge-a
    (s004 also on amisad-edge-b, with attested region identity).
```

Após o primeiro login de cada VM, conduzido uma única vez por OCR em `start.guest`, tudo é executado por
SSH com a chave do harness e sudo sem senha.

Os dois pontos de entrada no hospedeiro usam o mesmo auxiliar de admissão dos nós de borda: iniciam ambos antes
de aguardar e exigem um relatório de IP recente e válido de cada um. Um relatório ausente ou uma falha
na inicialização interrompe a execução antes dos cenários. Veja as
[restrições de orquestração no hospedeiro](https://yuruna.link/42010605-0006) e a
[fronteira de confiança do download](https://yuruna.link/42010605-0008).

<a id="run"></a>

## Execução

Execute em `pwsh` -- em um hospedeiro Hyper-V, ele deve estar **elevado** (KVM e UTM controlam o
hipervisor como o usuário que fez a chamada, portanto não precisam de elevação; o orquestrador verifica
o requisito aplicável ao hospedeiro detectado antes de acessar uma VM):

```powershell
pwsh poc/build/run-tests.ps1 -NoConfigGate
```

`run-tests.ps1` remove todas as VMs de laboratório amisad e as VMs `test-*` remanescentes
(para garantir um início limpo), exclui uma chave de demonstração encontrada na árvore servida pelo
status service, resolve o endereço do stash service e interrompe a execução imediatamente se
nenhum responder (veja a etapa 4 da [configuração inicial](#one-time-setup)), monta a
topologia, entrega aos nós de borda a chave pública de demonstração do amisad-core (veja
[usernames.md](usernames.md#core-edge-access)) e executa, em ordem, cada cenário de seu
registro. Uma execução bem-sucedida termina com `ALL SCENARIOS PASSED`,
deixando `amisad-core` e as duas VMs de borda em execução como ambiente da demonstração. Os logs das etapas
ficam em `<temp>/amisad-tests/` (substitua com `-LogDir`); acompanhe o progresso em
`http://localhost:8080/status/`. Espere ~15 min para a compilação, ~15 min por
nó de borda, ~20 min para vm-core e alguns minutos por cenário.

**Execuções sem interface gráfica.** As teclas enviadas à interface gráfica no primeiro login só são confiáveis enquanto uma tela
está sendo renderizada. Para execuções sem supervisão, habilite uma vez a tela virtual do framework
(`[Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY','1','User')`);
caso contrário, mantenha uma sessão ativa de console/RDP no hospedeiro durante o provisionamento.

**Entrega do repositório.** Os convidados baixam `/yuruna-project-archive.tar.gz` do
status service do hospedeiro. Ele arquiva o HEAD do clone `<RepoRoot>/project` do framework,
com `poc/`, `test/` e o restante do projeto na raiz do arquivo. O
executor preenche esse clone a partir de `repositories.projectUrl`; edições sem commit
são excluídas. Tanto o [script de compilação](../../../poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh)
quanto o [script de implantação](../../../poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh)
usam esse endpoint e verificam o conteúdo recebido antes de extraí-lo (veja
[Downloads internos verificados](#verified-nested-downloads)). O caminho de produção (mantido para uso futuro) faz um clone Git com o
PAT do cofre em uma etapa `sensitive: true`.

**Armazenamento persistente.** A etapa de banco de dados provisiona o banco `amisad` com o papel de aplicação
`amisad` (senha fixa de laboratório `amisadpoc2026` -- ela é incluída em uma URL, por isso
é alfanumérica), abre `listen_addresses`/pg_hba para as redes dos pods e dos nós
e concede SELECT e INSERT nas três tabelas de ledger que só permitem acréscimos,
sem conceder UPDATE ou DELETE. Também concede SELECT, INSERT e UPDATE em
`ledger.settlement_instructions`. A mesma
papel de aplicação recebe SELECT, INSERT e UPDATE em `seller.offers`, `seller.orders`
e `seller.inventory`; o acesso ao inventário é necessário tanto na inicialização do serviço seller
quanto nas atualizações de estoque.
`deploy.sh` passa `DATABASE_URL` (IP do nó:5432)
para ledger-svc e seller-svc pelo valor Helm `databaseUrl`; as gravações
vão primeiro para o PostgreSQL, e os pods recarregam o estado na inicialização. s001 verifica se as linhas
foram gravadas e se um `kubectl rollout restart` recarrega as cadeias verificáveis e o
pedido liquidado; s002 verifica a linha do agendamento reservado; s003 verifica as
seis linhas de concessão/revogação/nova concessão da cadeia de consentimento; s004 verifica todas as doze
linhas de atestação; s005, a liquidação ampliada em 5 vias; s006, as linhas de consentimento de
concessão+revogação do mandato; s007, a oferta com quantidade zerada por um delta saindo do catálogo;
s008, os lançamentos de ajuste compensatórios + a concessão de divulgação; s010, a
certificação independente em quatro dimensões e a localização de adulterações. Um
`databaseUrl` vazio (o padrão do chart) mantém um serviço em memória -- é assim que `cargo test`
e os serviços básicos são executados.

Os snapshots `amisad-core-k8s` e `amisad-core` existentes, criados antes da concessão de acesso ao inventário,
precisam ser reconstruídos ou reparados antes de serem reutilizados. O ciclo completo normal
remove e recria essas VMs automaticamente. Para um laboratório mantido, aplique o
`db/schema.sql` atual como administrador do banco de dados e execute o comando abaixo no banco
`amisad`. Capture novamente o snapshot de infraestrutura reparado e reconstrua a partir dele
o snapshot `amisad-core` implantado; para uma VM implantada em execução, reinicie seller após
aplicar a concessão:

```sql
GRANT SELECT, INSERT, UPDATE ON seller.inventory TO amisad;
```

<a id="verified-nested-downloads"></a>

## Downloads internos verificados

O framework verifica o script iniciado por uma sequência contra um SHA-256 que o hospedeiro
insere no comando de inicialização, por SSH, nunca contra um valor trazido pelo próprio
download. Isso protege o script iniciado, mas não o que ele baixa
depois. Os scripts de convidado daqui baixam mais conteúdo -- um arquivo tar do projeto que extraem e
compilam, um arquivo SQL que executam como o superusuário `postgres`, um arquivo tar de binários que
transformam em imagens executadas como root -- pelo HTTP sem criptografia dos status service e stash service, em que
quem responde à requisição determina os bytes. Portanto, cada uma dessas entradas é verificada
contra um SHA-256 incluído no **mesmo comando de inicialização** (o `command:` da
etapa `sshFetchAndExecute`), calculado no hospedeiro durante a etapa e **antes** de a entrada
ser extraída, instalada ou executada. O digest é a fronteira de confiança; o listener de status
oferece apenas HTTP, portanto não há outro transporte a preferir.

| Entrada | Script | Variável no comando de inicialização | De onde o hospedeiro a obtém |
| --- | --- | --- | --- |
| Arquivo tar do projeto | compile, deploy | `AMISAD_PROJECT_ARCHIVE_SHA256` | `${ext:digest.GetArchiveSha256(project)}`: o arquivo tar é solicitado ao status service por loopback, e os bytes da resposta são submetidos ao hash. |
| `poc/db/schema.sql` | db | `AMISAD_SCHEMA_SHA256` | `${ext:digest.GetFileSha256(project/poc/db/schema.sql)}`: o arquivo servido pelo serviço. |
| Arquivo tar dos binários do stash | deploy | `AMISAD_BINARIES_SHA256` | `${ext:digest.GetPublishedSha256(amisad-binaries)}`: logo após a compilação enviar os binários, a etapa `callExtension` da sequência de compilação solicita à **VM de compilação** o SHA-256 do arquivo que ela criou, pelo canal SSH do harness. |

Cada script verifica o download, exclui-o quando há divergência e falha de forma segura com
código de saída 7 e uma mensagem que identifica a variável quando o digest está **ausente** -- um valor vazio
significa que o hospedeiro não conseguiu calculá-lo (o aviso está no log do hospedeiro) ou que o
script foi iniciado manualmente. Uma execução manual sem digest pode definir
`AMISAD_ALLOW_UNVERIFIED=1`: nesse caso, o download é usado como recebido e um banner
de aviso informa isso. Nenhuma sequência define essa variável; um digest incorreto continua sendo rejeitado, e um
digest malformado é rejeitado mesmo quando ela está definida. Os downloads ficam em um diretório privado
(modo 0700), não soltos em `/tmp`, e o esquema chega a `psql` pela entrada padrão, para que
outro usuário local não possa trocar um arquivo entre sua verificação e seu uso.

**O digest do arquivo é calculado sobre os bytes exatos que o serviço serve.** O arquivo tar é
criado sob demanda a partir do HEAD do clone do projeto, com dois arquivos auxiliares contendo a origem
e o commit. Gerar novamente o arquivo de um mesmo commit produz bytes idênticos -- as entradas tar contêm a
hora do commit e valores fixos de proprietário, e o cabeçalho gzip não contém timestamp, como verifica a
suíte de arquivos do framework -- e o serviço também guarda o arquivo criado por
commit, para que o download posterior ao hash receba os bytes sobre os quais o hash foi calculado. Se
o HEAD do clone mudar entre as duas operações (um `git pull` em `project/` no meio da etapa), o
convidado rejeita o download; execute a etapa novamente.

**O arquivo tar de binários é selecionado pelo digest, não pela data mais recente.** O stash é compartilhado
por todo o laboratório; outra execução ou outro hospedeiro pode enviar o mesmo rótulo após a compilação
desta execução. O script de implantação examina os dez envios mais recentes em busca daquele cujo
SHA-256 corresponde ao da compilação. Assim, um envio alterado ou substituído em seu caminho
pelo stash é rejeitado, e um laboratório movimentado não entrega a uma execução os binários de outra.

**As versões dos fornecedores são fixadas, não consideradas confiáveis pelo transporte.** `rustup-init` (uma versão
específica, em vez de encaminhar o instalador rustup.rs para `sh`), `bazelisk` (uma versão
específica, em vez do que `latest` representar naquele dia) e o arquivo tar do servidor NATS
são baixados de seus distribuidores e depois executados ou instalados como root. Cada um é
verificado contra o SHA-256 do próprio distribuidor, fixado no script que faz o download:
o `.sha256` ao lado de cada `rustup-init`, o digest exibido pelo GitHub em cada artefato de versão do bazelisk
e o `SHA256SUMS` da versão NATS. Os valores fixados ficam em um script que
o framework verificou contra o digest inserido pelo hospedeiro no comando de inicialização,
portanto têm exatamente o mesmo nível de confiança desse script. Para atualizar uma versão, altere-a e
seus digests juntos.

`test/download_contracts.py` e `test/nats_installer_contracts.py` verificam tudo
isso: as cópias dos auxiliares permanecem idênticas, cada script verifica antes de extrair, os
comandos de inicialização incluem cada variável lida pelo respectivo script, e um download que
não corresponde ao digest é rejeitado e removido.

**Itens deliberadamente fora do escopo:**

- `apt-get install`, `cargo` (com o `Cargo.lock` versionado) e `npm` (com
  `package-lock.json`): os próprios gerenciadores de pacotes verificam índices assinados ou
  hashes dos arquivos de bloqueio.
- Os arquivos de módulos e de cadeias de ferramentas do Bazel: o Bazel os verifica contra os
  hashes de integridade do registro.
- As imagens base de contêiner baixadas durante `docker build` (`rust:*-slim` e a
  base de runtime distroless): referenciadas por tag, não por digest. As imagens que executam
  os dez serviços são compiladas localmente a partir dos binários verificados.

<a id="project-archive-helper"></a>

## Auxiliar de arquivamento do projeto

[build/Publish-ProjectArchive.ps1](../../../poc/build/Publish-ProjectArchive.ps1) publica o
HEAD com commit deste checkout em `<yuruna-root>/project-poc.tar.gz`, servido em
`/yuruna-repo/project-poc.tar.gz`. Publique novamente após um commit quando usar esse
arquivo manual; ele exclui alterações sem commit. Os scripts de convidado ativos usam
o endpoint de arquivo do projeto descrito acima, portanto as execuções normais de teste e demonstração
não precisam desse auxiliar.

<a id="snapshot-page-cache-flush"></a>

## Gravação do cache de páginas antes do snapshot

As etapas de convidado que terminam em um snapshot finalizam com `sync`. O hospedeiro congela o
disco da VM para o snapshot assim que a etapa termina, sem solicitar primeiro que o
convidado grave os dados pendentes; o que ainda estiver no cache de páginas naquele
instante não entra no snapshot. A falha é silenciosa e só aparece depois --
o arquivo continua legível pelo restante da sessão SSH e só desaparece
quando o snapshot é restaurado -- portanto ela surge longe de sua causa, na
primeira sequência posterior que precisar da gravação perdida: uma ferramenta perdida resulta em
"command not found"; um binário ou arquivo de unidade de serviço perdido deixa uma VM restaurada
cujos dependentes iniciam contando com um serviço inexistente; e uma gravação perdida de
`/etc/shadow` deixa usuários cujos logins aceitam apenas suas senhas
antigas. Arquivos grandes gravados recentemente são perdidos primeiro: um binário de 8 MB
instalado como última ação de um script ainda não ultrapassou o intervalo de
gravação pendente do sistema de arquivos, ao contrário dos arquivos pequenos gravados segundos antes.
Os scripts de convidado descarregam o cache no fim de suas próprias execuções; uma sequência cuja última gravação
é feita por um `sshExec` inline (que não tem essa etapa final) acrescenta uma etapa explícita de `sync`
antes do snapshot.

<a id="stash-artifact-naming"></a>

## Nomenclatura dos artefatos do stash

A etapa de compilação empacota os binários de lançamento como `amisad-<arch>-binaries.tgz`
(`<arch>` obtido de `uname -m`), e a etapa de implantação baixa apenas o rótulo
correspondente à sua própria arquitetura. O stash é um serviço compartilhado por todo o
laboratório, portanto o nome do artefato precisa indicar qual código de máquina contém: se todos os
hospedeiros enviassem para um único rótulo, o envio mais recente responderia a todas as solicitações,
e um convidado que recebesse a compilação de outra arquitetura teria binários que seu kernel
não pode executar -- todos os pods terminariam com "exec format error", e a implantação só
informaria um timeout de rollout, longe da causa.

A arquitetura fica no meio do nome de propósito. O stash faz a correspondência dos
nomes de arquivo por substring; um hospedeiro que ainda pedisse o rótulo simples `amisad-binaries`
continuaria encontrando a forma com sufixo `amisad-binaries-<arch>` e permaneceria
exposto; esse rótulo não corresponde a `amisad-<arch>-binaries`. Os hospedeiros adotam o
rótulo qualificado por arquitetura no seu próprio ritmo, sem nunca receber uma compilação
de outra arquitetura.

<a id="adding-a-scenario"></a>

## Adição de um cenário

1. Implemente o script de execução do convidado em `poc/test/ubuntu.server.24/`
   (`ubuntu.server.24.amisad-core.sNNN.<word>.sh`) e a sequência em
   `poc/test/`. Comece pelo conjunto s001-s004: encadeie para
   `...amisad-core.deploy`, use `requiresSnapshot`/`loadDiskSnapshot`
   `amisad-core`, `username: amisad-core-admin` e `hostname: amisad-core`.
   `component:` é um único bloco `retry` -- `loadDiskSnapshot`,
   `sshWaitReady` e depois `sshFetchAndExecute` de
   `...amisad-core.ready.sh`, que reinicia os serviços implantados nos pods
   existentes agora e espera que todos os NodePorts respondam. `workload:` é
   `sshFetchAndExecute` do script do cenário mais `saveSystemDiagnostic`,
   deliberadamente fora do retry: preparar o cluster é
   idempotente e justifica uma segunda tentativa, enquanto um cenário que só passa
   ao ser repetido está apontando um defeito. Portanto, o script do cenário pressupõe um
   cluster ativo e começa em sua primeira chamada -- sem uma verificação de prontidão própria.
2. Acrescente o nome da sequência ao registro `$Scenarios` em
   `poc/build/run-tests.ps1`.
3. Os dois nós de borda são iniciados pelo orquestrador e permanecem em execução; resolva o endereço de qualquer um
   pelo relatório de IP enviado ao status-server (veja o script s004).
4. Atualize [usernames.md](usernames.md) e este arquivo se o padrão mudar.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.

<a id="focused-recovery-and-packaging-checks"></a>

## Verificações específicas de recuperação e empacotamento

Após `cargo build --workspace --locked`, execute `python3 test/service_contracts.py`
e `python3 test/check_messages.py`. Para verificar a recuperação persistente do inventário e das liquidações,
aplique `db/schema.sql` a um banco de dados PostgreSQL descartável, defina
`AMISAD_TEST_DATABASE_URL` e execute `python3 test/service_contracts.py DurableContracts`.
Esses testes criam registros e reiniciam seus próprios processos locais de serviço.

`python3 test/build_contracts.py`, `python3 test/nats_installer_contracts.py` e
`pwsh test/host_contracts.ps1` usam caminhos descartáveis e comandos nativos substituídos por implementações de teste;
eles não modificam o firewall do hospedeiro, não instalam serviços de sistema nem implantam VMs.
Execute `flutter test` e `flutter analyze` em `components/apps/buyer-flutter` para
verificar prazos limite de requisição, navegação/liberação de recursos e respostas desatualizadas.

Os diagnósticos HTTP dos cenários e a resolução dos nós de borda são compartilhados em `test/amisad-scenario.sh`,
carregado do arquivo extraído do projeto. `build/Publish-ProjectArchive.ps1`
é o comando canônico de arquivamento; `build/serve-local.ps1` encaminha a chamada por compatibilidade.
Seller e ledger compilam diretamente o módulo de banco de dados `amisad-common/src/database.rs`;
a biblioteca common em si continua usando apenas std. Erros SQL retornam
503 sem encerrar uma conexão ativa; uma conexão fechada provoca a saída para reinicialização.
`test/database_policy_contracts.py` verifica os dois casos em um banco de dados PostgreSQL
descartável escolhido por `DATABASE_POLICY_URL` (nunca use um banco de laboratório existente).
Execute-o com uma conexão administrativa a um cluster PostgreSQL descartável e
`PSQL` apontando para `psql` se ele estiver fora do PATH. Seu teste de regressão de provisionamento aplica
`db/schema.sql` e o bloco real de concessões do script de banco de dados do convidado em uma transação revertida;
depois, faz leituras e gravações de inventário com o papel `amisad`, sem privilégios de superusuário,
e verifica se UPDATE/DELETE do ledger continuam proibidos. Execute essa
verificação isoladamente com:

```bash
python3 test/database_policy_contracts.py DatabasePolicy.test_provisioned_inventory_permissions -v
```

A SPA oferece recuperação de rotas desconhecidas em inglês, português, chinês e
hebraico. As traduções são rascunhos de máquina com hashes da fonte em
`messages.provenance.json`; `python3 test/check_messages.py` verifica a completude,
as chaves não usadas e a desatualização. `node test/low_browser_contracts.cjs` testa a SPA compilada
com o Chrome; `PLAYWRIGHT_MODULE` e `CHROME_PATH` podem substituir os caminhos das ferramentas locais.
