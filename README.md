# API de Controle de Hábitos

API REST feita em Dart para criar hábitos pessoais, registrar realizações por dia e acompanhar a frequência. O projeto contém somente o backend; o aplicativo Flutter pode consumir as rotas HTTP descritas abaixo.

## Tecnologias

- Dart 3.10 ou superior
- Shelf e shelf_router para servidor HTTP e rotas
- SQLite para persistir hábitos e realizações no arquivo `habits.db`

## Como executar

1. Instale o [Dart SDK](https://dart.dev/get-dart) 3.10 ou superior.
2. Clone este repositório e abra a pasta do projeto.
3. Baixe as dependências e inicie o servidor:

   ```bash
   dart pub get
   dart run
   ```

Por padrão, o servidor inicia na porta `8080` e cria o banco `habits.db` na pasta atual. A porta e o caminho do banco podem ser configurados por variáveis de ambiente:

```bash
# PowerShell
$env:PORT = "3000"
$env:DATABASE_PATH = "data/habits.db"
dart run
```

O servidor escuta em `0.0.0.0`, permitindo que um celular na mesma rede Wi-Fi acesse o computador. No Flutter, substitua `SEU_IP_LOCAL` pelo endereço IP da máquina que executa a API. Para Android Emulator, normalmente use `10.0.2.2`; para iOS Simulator, normalmente `localhost`.

```dart
const apiBaseUrl = 'http://10.0.2.2:8080';
```

Em dispositivo físico, use por exemplo `http://192.168.0.10:8080` e permita a conexão do Dart no firewall local, se solicitado.

## Formato geral

- Base URL local: `http://localhost:8080`
- Cabeçalho para envio de JSON: `Content-Type: application/json`
- Datas: `YYYY-MM-DD`
- As respostas de sucesso e erro usam JSON, exceto operações `DELETE`, que retornam `204 No Content`.
- Códigos de erro: `400` entrada inválida, `404` recurso/rota inexistente, `409` realização já registrada no dia, `500` erro inesperado.

## Rotas

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/health` | Confere se a API está funcionando |
| `GET` | `/habits` | Lista hábitos ativos |
| `GET` | `/habits?includeInactive=true` | Inclui hábitos inativos (para uso futuro) |
| `POST` | `/habits` | Cria um hábito |
| `GET` | `/habits/{id}` | Busca um hábito |
| `PUT` | `/habits/{id}` | Atualiza um hábito |
| `DELETE` | `/habits/{id}` | Exclui um hábito e seus registros |
| `POST` | `/habits/{id}/completions` | Registra a realização em uma data |
| `GET` | `/habits/{id}/completions` | Lista realizações, com filtros opcionais |
| `DELETE` | `/habits/{id}/completions/{date}` | Remove uma realização daquele dia |
| `GET` | `/habits/{id}/stats?from={data}&to={data}` | Calcula frequência no período |

### Criar hábito

`POST /habits`

```json
{
  "name": "Ler",
  "description": "Ler um pouco antes de dormir",
  "targetDaysPerWeek": 5
}
```

`name` é obrigatório. `description` é opcional. `targetDaysPerWeek` aceita um inteiro de 1 a 7 e assume `7` quando omitido. Exemplo de resposta (`201 Created`):

```json
{
  "id": 1,
  "name": "Ler",
  "description": "Ler um pouco antes de dormir",
  "targetDaysPerWeek": 5,
  "active": true,
  "createdAt": "2026-11-11 12:00:00"
}
```

### Registrar uma realização

`POST /habits/1/completions`

```json
{ "date": "2026-11-11" }
```

Se `date` for omitida, a API usa a data atual do servidor. Só pode existir um registro por hábito e data; uma tentativa duplicada retorna `409 Conflict`.

### Consultar registros e frequência

- `GET /habits/1/completions?from=2026-11-01&to=2026-11-30`
- `GET /habits/1/stats?from=2026-11-01&to=2026-11-30`

Na rota de estatísticas, `from` e `to` são opcionais: por padrão, o intervalo vai do primeiro dia do mês atual até hoje. A resposta informa total de realizações, média semanal e percentual em relação à meta semanal distribuída pelos dias do intervalo. O percentual fica limitado a 100%.

Exemplo:

```json
{
  "habitId": 1,
  "from": "2026-11-01",
  "to": "2026-11-30",
  "totalCompletions": 12,
  "daysInPeriod": 30,
  "averagePerWeek": 2.8,
  "targetDaysPerWeek": 5,
  "targetCompletionPercent": 40
}
```

## Exemplos com curl

```bash
curl http://localhost:8080/health

curl -X POST http://localhost:8080/habits \
  -H "Content-Type: application/json" \
  -d '{"name":"Beber água","targetDaysPerWeek":7}'

curl -X POST http://localhost:8080/habits/1/completions \
  -H "Content-Type: application/json" \
  -d '{"date":"2026-11-11"}'

curl "http://localhost:8080/habits/1/stats?from=2026-11-01&to=2026-11-30"
```

## Estrutura do projeto

```text
lib/
  main.dart        # Inicialização, rotas HTTP, validação e acesso ao SQLite
README.md          # Instruções e documentação das rotas
pubspec.yaml       # Dependências Dart
```

O código inclui comentários nos pontos principais para apoiar o estudo. O arquivo SQLite e os arquivos locais de configuração não devem ser enviados ao GitHub; eles já estão cobertos pelo `.gitignore`.

## Escopo

Esta versão é adequada para estudo e execução local. Ela não implementa usuários, login ou separação dos dados por pessoa. Para uma publicação pública, esses recursos e uma configuração de hospedagem devem ser definidos antes de disponibilizar os dados na internet.
