# daikin

Controle local, em Swift, de ar-condicionado Daikin vendido no Brasil (os que usam o app
**Daikin Smart AC**). Fala direto com o aparelho pela rede Wi-Fi, sem passar pela nuvem.

- `DaikinKit` — biblioteca com o protocolo, a descoberta e os modelos.
- `DaikinApp` — app para macOS em SwiftUI.
- `daikin` — CLI em cima da biblioteca.

Sem dependências externas: só Foundation, Network e CommonCrypto.

Projeto pessoal, não oficial e sem vínculo com a Daikin. Só fala com aparelhos na sua própria rede, usando a
Device Key que o app oficial entrega ao dono do aparelho.

## App

```bash
Scripts/build-app.sh
```

Gera `build/Daikin.app`; arraste para a pasta Aplicativos se quiser. Na primeira abertura o macOS pede
acesso à **Rede Local** — sem ele o app não alcança o aparelho. O app usa a mesma configuração do CLI,
então um aparelho salvo por um aparece no outro; sem nenhum salvo, ele abre na tela de adicionar.

A assinatura é ad-hoc. Depois de recompilar, o macOS pode tratar o app como novo e pedir a permissão outra
vez (ou negar em silêncio: nesse caso, religue em Ajustes do Sistema → Privacidade e Segurança → Rede Local).
Para assinar com uma identidade sua: `CODESIGN_IDENTITY="Apple Development: …" Scripts/build-app.sh`.

Atalhos: ⇧⌘P liga/desliga, ⌘↑ e ⌘↓ mudam a temperatura, ⌘R atualiza.

### Barra de menus

O app põe um item na barra de menus: o ícone fica preenchido com o ar ligado e mostra a temperatura
ambiente ao lado. Um clique abre um painel com os mesmos controles da janela.

Fechar a janela não encerra o app; ele continua na barra. Para trazê-la de volta, use **Abrir janela** no
painel ou clique no ícone do Dock. Para sair de vez, ⌘Q ou **⋯ → Encerrar Daikin**. No mesmo menu **⋯** fica
**Abrir ao iniciar sessão**, que registra o app nos Itens de Início do macOS.

## CLI

```bash
swift build -c release
```

O binário fica em `.build/release/daikin`.

### 1. Pegar a Device Key

No app do celular: **Menu → Integrações → Home Assistant**, selecione o SSID e toque em **Enviar**.
A chave é um texto em Base64 e é única por aparelho.

### 2. Salvar o aparelho

```bash
swift run daikin setup
```

Ele procura o aparelho na rede, pede a chave (sem ecoar), confere se ela decifra a resposta e grava em
`~/.config/daikin/config.json` (permissão `600`).

### 3. Controlar

```bash
daikin status
daikin on
daikin off
daikin set --temp 23 --mode cool --fan quiet
daikin set --swing on --econo on
daikin get device          # JSON decifrado de acstatus | device | status
daikin send '{"streamer":1}'   # campos crus, para explorar o que o seu modelo aceita
```

`daikin help` lista tudo.

## Protocolo

O módulo Wi-Fi é da iota labs e expõe um servidor HTTP na porta **15914**.

**Descoberta.** Bonjour, serviço `_iota._tcp`, instância `Daikin Smart AC`, com `apn=DAIKIN:<MAC>` no TXT.
A porta anunciada (80) está fechada; o que vale é o host. O hostname mDNS é `DAIKIN` + os três primeiros
bytes do APN invertidos: `DAIKIN:A1B2C3D4E5F6` → `DAIKINC3B2A1.local`.

**Endpoints.**

| Método | Caminho | Conteúdo |
|---|---|---|
| GET | `/acstatus` | estado do ar (`port1`) |
| POST | `/acstatus` | altera campos de `port1`; responde com o estado novo |
| GET | `/device` | identificação e capacidades do módulo |
| GET | `/status` | estado da conexão (Wi-Fi, nuvem) |

**Corpo.** Sempre Base64 de um quadro binário:

```
requisição:  IV (16) | AES-CFB(json + "BZ")                  | CRC16 (2, little-endian)
resposta:    IV (16) | tamanho & 0xFF (1) | AES-CFB(json)   | CRC16 (2, little-endian)
```

- AES-128 em modo CFB com segmento de 128 bits, sem padding; a chave é a Device Key decodificada.
- CRC-16/GENIBUS (polinômio `0x1021`, inicial `0xFFFF`, xor final `0xFFFF`) sobre tudo o que vem antes dele.
- O sufixo `BZ` depois do JSON é obrigatório nas requisições.
- CFB não autentica: com a chave errada a resposta "decifra" em lixo. O cliente trata JSON inválido como chave errada.

**HTTP fora do padrão.** O aparelho prefixa cada cabeçalho com tabs
(`HTTP/1.1 200 OK\r\n\t\tContent-Type: …`), o que faz URLSession e curl rejeitarem a resposta. Por isso o
transporte é um socket TCP cru (`RawHTTP.swift`).

**Campos de `port1`.**

| Campo | Valores |
|---|---|
| `power` | 0, 1 |
| `mode` | 1 automático, 2 desumidificar, 3 resfriar, 4 aquecer, 6 ventilar |
| `temperature` | graus Celsius, inteiro |
| `fan` | 3 baixa, 4 média-baixa, 5 média, 6 média-alta, 7 alta, 17 automática, 18 silenciosa |
| `v_swing` | oscilação vertical, 0/1 |
| `coanda` | modo conforto, 0/1 |
| `econo` | modo econômico, 0/1 |
| `powerchill` | modo potente, 0/1 |
| `sensors.room_temp`, `sensors.out_temp` | leitura, só na resposta |

Comando: `{"port1":{"power":1,"temperature":24}}` — só os campos enviados mudam.

## Testes

```bash
swift test
```

Cobrem CRC, AES-CFB (vetor do NIST e um gerado com OpenSSL), o enquadramento, o parser HTTP e os modelos.
Não tocam no aparelho.

### Aparelho simulado

`Scripts/mock-device.py` fala o mesmo protocolo em `127.0.0.1:15914` (Python + `openssl`, sem dependências).
Serve para mexer no app e no CLI, comandos inclusive, sem tocar no ar de verdade, e imprime cada comando recebido.

```bash
Scripts/mock-device.py --state '{"power":0}'
```

```bash
daikin status --host 127.0.0.1 --key AAECAwQFBgcICQoLDA0ODw==
```

A variável `DAIKIN_CONFIG` troca o arquivo de configuração do app e do CLI; aponte para um arquivo cujo
aparelho seja `127.0.0.1` para abrir o app no simulado. Em builds de debug (`Scripts/build-app.sh debug`),
`DAIKIN_SNAPSHOT=/caminho.png` salva uma imagem da janela, do painel ou do item da barra e encerra, e pode
antes clicar em menus e controles — veja `Sources/DaikinApp/Snapshot.swift`. Cliques só são aceitos quando
todo aparelho salvo está em localhost.

## Fontes

O protocolo não foi descoberto do zero: está publicado em código aberto, inclusive pela própria Daikin Brasil.

- [daikin-br/pyiotdevice](https://github.com/daikin-br/pyiotdevice) e
  [daikin-br/ha-custom-integration](https://github.com/daikin-br/ha-custom-integration) — cliente oficial em Python.
- [crossworth/daikin](https://github.com/crossworth/daikin) — engenharia reversa original, em Go.
- [billbatista/ha-daikin-smart-ac-br](https://github.com/billbatista/ha-daikin-smart-ac-br) — ponte MQTT em Go.

## Licença

[MIT](LICENSE).
