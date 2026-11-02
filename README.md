# LiberaPorta

**Gerencie o acesso a servidores locais pela rede com poucos comandos no Windows.**

O **LiberaPorta** é um utilitário para Windows 10 e 11 que permite **liberar, fechar, listar e diagnosticar portas TCP** usadas por aplicações locais, como servidores de desenvolvimento, APIs e aplicações web. Ele configura regras do Firewall do Windows e, quando necessário, cria um redirecionamento para serviços que escutam apenas em `localhost`.

O projeto é distribuído como um **único script híbrido Batch + PowerShell**, sem instalador e sem dependências de terceiros.

> **Versão identificada no código:** 1.1  
> **Escopo:** acesso pela rede local (LAN). O LiberaPorta não configura roteadores nem publica serviços automaticamente na internet.

## Sumário

- [Funcionalidades](#funcionalidades)
- [Requisitos](#requisitos)
- [Como usar](#como-usar)
- [Comandos disponíveis](#comandos-disponíveis)
- [Exemplo de uso](#exemplo-de-uso)
- [Como funciona](#como-funciona)
- [Arquivos de estado e logs](#arquivos-de-estado-e-logs)
- [Segurança e cuidados](#segurança-e-cuidados)
- [Solução de problemas](#solução-de-problemas)
- [Limitações conhecidas](#limitações-conhecidas)
- [Estrutura do projeto](#estrutura-do-projeto)

## Funcionalidades

| Recurso | Descrição |
| --- | --- |
| Liberação de portas | Cria regras de entrada TCP no Firewall do Windows para a porta informada. |
| Fechamento de portas | Remove regras criadas pelo LiberaPorta e redirecionamentos correspondentes; pode identificar permissões de outras regras. |
| Acesso restrito à rede local | Usa `RemoteAddress LocalSubnet` nas regras que cria. |
| Detecção da rede | Identifica o IPv4 de uma interface conectada, dando preferência ao Wi-Fi. |
| Redirecionamento de `localhost` | Usa `netsh interface portproxy` se o serviço estiver escutando apenas em `127.0.0.1`, `::1` ou outro endereço específico. |
| Diagnóstico | Examina processo, endereço de escuta, firewall, redirecionamento e conectividade TCP local. |
| Listagem | Mostra as portas registradas no estado do utilitário. |
| Operações em lote | Aceita várias portas nos comandos `abrir` e `fechar`. |
| Persistência | Mantém um arquivo de estado e um log de operações. |
| Atualização do IP | Ao iniciar novamente o script, tenta atualizar os redirecionamentos registrados caso o IP local tenha mudado. |
| Elevação de privilégios | Solicita execução como administrador quando necessário. |

## Requisitos

- **Windows 10 ou Windows 11**, conforme a verificação implementada no código.
- **Windows PowerShell** e os comandos de rede e firewall fornecidos pelo Windows, incluindo o módulo `NetSecurity` e o utilitário `netsh.exe`.
- **Permissão de administrador** para alterar as configurações do firewall e dos redirecionamentos.
- Conexão de rede ativa, Wi-Fi ou Ethernet, com endereço IPv4 e gateway padrão, para liberar uma porta.
- Para o redirecionamento via `portproxy`, disponibilidade do serviço **Auxiliar IP** (`iphlpsvc`).

Não é necessário instalar Node.js, Python, bibliotecas adicionais ou executar um instalador para usar o utilitário. A aplicação cujas portas serão liberadas deve ser iniciada separadamente.

## Como usar

1. Salve o arquivo `LiberaPorta.bat` em uma pasta de sua preferência.
2. Abra-o com **duplo clique** para acessar o menu interativo ou execute-o pelo **Prompt de Comando** ou pelo **PowerShell**.
3. Autorize a solicitação do Windows (UAC), caso apareça.
4. Selecione a operação e informe uma porta TCP válida, de **1 a 65535**.
5. Para um serviço web em execução, utilize o endereço IPv4 e a porta apresentados pelo utilitário em outro dispositivo da mesma rede local.

### Menu interativo

| Opção | Ação |
| --- | --- |
| `1` | Liberar uma porta |
| `2` | Fechar uma porta |
| `3` | Listar portas registradas |
| `4` | Diagnosticar uma porta |
| `5` | Fechar todas as portas registradas como liberadas pelo LiberaPorta |
| `0` | Sair |

> **Atenção ao nome do arquivo:** o script recebido chama-se `LiberaPorta.bat`. Alguns textos de ajuda internos mencionam `LiberaPorta.cmd`; nos exemplos deste README é usado o nome efetivo do arquivo fornecido. Os comandos devem ser adaptados se você renomear o arquivo.

## Comandos disponíveis

No **Prompt de Comando (CMD)**, dentro da pasta onde está o arquivo:

```bat
:: Abrir o menu interativo
LiberaPorta.bat

:: Liberar uma porta TCP
LiberaPorta.bat abrir 8080

:: Liberar várias portas TCP
LiberaPorta.bat abrir 5173 8080 3000

:: Fechar uma porta
LiberaPorta.bat fechar 8080

:: Fechar várias portas
LiberaPorta.bat fechar 5173 8080

:: Listar as portas registradas
LiberaPorta.bat listar

:: Diagnosticar uma porta
LiberaPorta.bat diagnostico 5173

:: Fechar todas as portas gerenciadas pelo utilitário
LiberaPorta.bat fechartodas

:: Exibir a ajuda
LiberaPorta.bat ajuda
```

No **PowerShell**, se estiver na mesma pasta, prefixe o nome do script com `./` ou `.\`:

```powershell
.\LiberaPorta.bat abrir 5173
.\LiberaPorta.bat diagnostico 5173
.\LiberaPorta.bat fechar 5173
```

**Aliases aceitos pelo código:** `liberar`/`open` para `abrir`; `close` para `fechar`; `list` para `listar`; `diag` para `diagnostico`; `closeall` para `fechartodas`; `help`, `/?` e `-h` para `ajuda`.

**Importante:** na execução por linha de comando, o modo é não interativo para as operações de abrir/fechar. Portanto, não solicita as mesmas confirmações do menu, inclusive para portas consideradas sensíveis ou para a desativação temporária de regras que bloqueiam o executável. Confira os argumentos antes de executar.

## Exemplo de uso

Imagine uma aplicação web de desenvolvimento executando na porta `5173` de um computador Windows.

1. **Inicie a aplicação** com o comando apropriado ao seu projeto.
2. No computador que hospeda a aplicação, abra o LiberaPorta e escolha **Liberar porta**, informando `5173`, ou execute:

   ```bat
   LiberaPorta.bat abrir 5173
   ```

3. Anote o endereço mostrado pelo script. **Exemplo ilustrativo** (o IP real é detectado na execução):

   ```text
   http://192.168.1.25:5173
   ```

4. Em outro computador ou celular conectado à mesma rede local, tente abrir o endereço no navegador.
5. Ao concluir o uso, remova a liberação criada:

   ```bat
   LiberaPorta.bat fechar 5173
   ```

O LiberaPorta também tenta copiar a URL apresentada para a área de transferência. **Liberar o firewall não inicia a aplicação**: a porta só responderá se houver um serviço ativo e acessível.

## Como funciona

O arquivo combina duas partes:

1. **Batch (CMD):** verifica o privilégio administrativo, solicita elevação via UAC se necessário e inicia o PowerShell.
2. **PowerShell:** detecta sistema e interface de rede, verifica a porta informada, administra regras do firewall, configura redirecionamento quando necessário e registra o estado.

### Quando a aplicação escuta na rede

Se o serviço já estiver vinculado ao endereço de rede ou a todas as interfaces (por exemplo, `0.0.0.0`), o utilitário pode liberar o tráfego TCP de entrada por uma regra de firewall.

### Quando a aplicação escuta apenas em localhost

Se o serviço estiver vinculado a `127.0.0.1` ou `::1`, o utilitário tenta criar um **portproxy**, encaminhando conexões destinadas ao IPv4 da rede para o endereço em que a aplicação escuta. Isso utiliza o serviço **Auxiliar IP** do Windows.

### Nome e escopo das regras

As regras criadas pelo projeto seguem o padrão:

```text
LiberaPorta-TCP-<PORTA>
```

A regra é de **entrada**, protocolo **TCP**, ação **Allow**, endereço remoto **LocalSubnet** e perfil **Any**. O grupo registrado no firewall é `LiberaPorta`.

Esse escopo não significa isolamento absoluto: outros dispositivos da sub-rede local podem conseguir conectar-se ao serviço, e regras existentes do Windows também influenciam o resultado.

## Arquivos de estado e logs

O script utiliza a pasta:

```text
C:\ProgramData\LiberaPorta\
```

| Arquivo | Finalidade |
| --- | --- |
| `estado.json` | Guarda as portas gerenciadas, endereços IP, modo de liberação, redirecionamentos, regras de bloqueio temporariamente desativadas e outros dados necessários para tentar reverter as alterações. |
| `liberaporta.log` | Registra operações e erros com data e hora. |

A pasta é criada automaticamente quando o utilitário é executado. Para manter o histórico de alterações e o mecanismo de reversão, evite excluir manualmente o `estado.json` enquanto houver regras gerenciadas ativas.

## Segurança e cuidados

- **Use apenas em redes confiáveis.** Uma porta liberada para `LocalSubnet` pode ser acessível por outros equipamentos da mesma sub-rede.
- **Não é uma ferramenta de publicação na internet.** Não configura NAT, encaminhamento de portas no roteador, DNS ou HTTPS.
- **Não cria autenticação ou criptografia.** A segurança dos dados, das rotas e das credenciais continua sendo responsabilidade da aplicação exposta.
- **Exige privilégios elevados.** O script altera regras do firewall e pode configurar `portproxy` ou iniciar o serviço `iphlpsvc`.
- **Portas sensíveis exigem atenção especial.** O código avisa sobre portas normalmente associadas a FTP, SSH, Telnet, RPC, NetBIOS, SMB, Área de Trabalho Remota e WinRM, mas não impede sua liberação. Evite expor esses serviços sem uma política de segurança apropriada.
- **Regras externas podem interferir.** Ao fechar uma porta pelo menu, o utilitário identifica algumas regras de outros programas e pode oferecer sua desativação. Isso pode interromper o acesso de outras aplicações; avalie antes de confirmar.
- **O fechamento não encerra o servidor.** O comando remove configurações de acesso gerenciadas, sem desligar o processo que está escutando na porta.
- **Revise operações em lote.** O modo não interativo pode desativar temporariamente regras de bloqueio de programa sem perguntar e, no fechamento, não desativa automaticamente regras externas que ainda permitam o acesso.

## Solução de problemas

### O endereço abre no próprio computador, mas não em outro dispositivo

Verifique se ambos estão na mesma rede local, se o IP apresentado está correto e se o roteador ou ponto de acesso utiliza **isolamento de clientes (AP isolation)**. Em redes corporativas, a política de segurança pode impedir a comunicação entre dispositivos.

Execute um diagnóstico:

```bat
LiberaPorta.bat diagnostico 5173
```

### A porta foi liberada, mas não responde

Confirme que a aplicação realmente está em execução na porta informada. O utilitário pode criar uma regra de firewall mesmo quando nenhum processo está escutando. Se a aplicação foi iniciada depois, execute novamente a liberação ou o diagnóstico para verificar se é necessário configurar redirecionamento.

### O redirecionamento de localhost não funciona

Confira se o serviço **Auxiliar IP (`iphlpsvc`)** está disponível, se a aplicação está escutando no endereço e na porta esperados e se há restrições adicionais de firewall. O diagnóstico mostra se o utilitário reconhece o redirecionamento.

### O IP do computador mudou

Ao iniciar novamente, o LiberaPorta tenta sincronizar o IP registrado e refazer os redirecionamentos sob seu controle. Essa atualização **não é um serviço de monitoramento contínuo em segundo plano**.

### A porta ainda está acessível após usar `fechar`

Pode haver uma regra de entrada criada por outra aplicação, por um administrador ou por uma política da organização. O LiberaPorta tenta identificar algumas dessas regras; fechar a porta no utilitário não garante revogação de todas as permissões possíveis. Faça a verificação também pelo Firewall do Windows e pela configuração do próprio serviço.

## Limitações conhecidas

- Gerencia **portas TCP**, não regras UDP.
- Seleciona uma interface de rede principal e prioriza Wi-Fi; redes com múltiplos adaptadores, VPNs ou interfaces virtuais podem exigir verificação adicional.
- A detecção da rede usada para liberar portas depende de **IPv4 com gateway padrão**.
- O redirecionamento é implementado pelo **portproxy do Windows**, com suas restrições próprias.
- O teste de conectividade implementado é uma **conexão TCP ao IP local**. Ele não substitui o teste real a partir de outro dispositivo e não valida respostas HTTP, HTTPS ou a segurança da aplicação.
- O estado é sincronizado **na execução**; não há um agente residente monitorando mudanças na rede.
- O comando `fechartodas` processa as portas registradas pelo LiberaPorta ou identificadas em seu grupo de regras, não todas as portas abertas no sistema.
- O código foi documentado por **inspeção estática**. A execução efetiva no Windows 10/11 e os cenários de firewall e redirecionamento ainda precisam ser validados em ambiente de teste.

## Estrutura do projeto

```text
LiberaPorta/
├── LiberaPorta.bat   # Script híbrido Batch + PowerShell
└── README.md         # Documentação do projeto
```

---

**LiberaPorta 1.1** — utilitário para facilitar o acesso a servidores locais durante desenvolvimento, demonstrações e testes em redes confiáveis.
