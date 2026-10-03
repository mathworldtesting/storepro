# ReadIt! book store

A small online book store built as three independent ASP.NET Core Razor Pages apps on .NET 8, one per folder:

| App | What it does | Local URL | Needs to run locally |
|---|---|---|---|
| `catalog/` | Lists books, "add to shopping cart", weather page (`/Weather`) | http://localhost:5000 (https 5001) | Nothing — uses an in-memory database |
| `inventory/` | Edits the stock count of each book | http://localhost:5002 (https 5003) | SQL Server / Azure SQL |
| `cart/` | Shows the shopping cart, removes items, places an order | http://localhost:5004 (https 5005) | SQL Server / Azure SQL, Redis, and an order-processing Azure Function |

The apps share no code. Each has its own copy of the `Book` model, `BookContext` and `wwwroot`. They work together through shared external services:

- **SQL `Books` table** (`ConnectionStrings:BooksDB`) — catalog lowers `InStock` when a book is added to the cart, cart raises it when a book is removed, inventory sets it directly.
- **Redis list `cart`** (`Redis:ConnectionString`) — catalog adds book IDs, cart reads and removes them.
- **Azure Function** (`OrderFunctionUrl`) — cart posts the order as JSON and empties the cart when the function answers `204 No Content`.

## Features

**catalog**
- Book list with name, price and stock count.
- **Load Books to DB** button that wipes the `Books` table and seeds four sample books.
- Add to shopping cart: lowers the book's stock and stores its ID in Redis; a book can be in the cart only once. *(Staged — off until Redis is configured.)*
- Cart item counter on the home page. *(Staged — off until Redis is configured.)*
- Weather page (`/Weather`) that fetches `http://<address you enter>/api/weather` from a separate weather service not included in this repo.
- Switchable database: in-memory (default) or SQL Server / Azure SQL.

**inventory**
- Lists every book with an editable stock count and saves changes to the shared `Books` table. *(Listing is staged — off until the connection string is set.)*

**cart**
- Shows the books currently in the Redis cart. *(Staged — off until the database is configured.)*
- Remove from cart: returns the book to stock and removes it from Redis.
- Place order: builds an order (random ID, date, items, total), posts it as JSON to the Azure Function, and clears the cart on success.
- Dockerfile and Kubernetes manifest (Deployment + LoadBalancer Service).

This is course material, so the staged features are deliberately commented out in the code until the matching infrastructure exists. [Setup](#setup) explains how to turn each one on.

## Installation

### Prerequisites

- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0). Tested with 8.0.416, 8.0.420 and 8.0.421.
- Optional, depending on which features you turn on:
  - SQL Server or Azure SQL database (inventory, cart, and catalog when not in-memory)
  - Redis, e.g. Azure Cache for Redis (catalog add-to-cart, cart)
  - An Azure Function that accepts the order JSON (cart place-order)
  - Docker and `kubectl` (cart container)
  - EF Core CLI for database migrations:
    ```bash
    dotnet tool install --global dotnet-ef
    ```

There are no Node or Python dependencies. The front-end libraries (Bootstrap, jQuery, jQuery Validation) are committed under each app's `wwwroot/lib`.

### Get the code and build

```bash
git clone <repo-url> StorePro
cd StorePro

dotnet restore && dotnet build            # catalog (the root solution contains only catalog)
dotnet build inventory/inventory.csproj
dotnet build cart/cart.csproj
```

The catalog and cart builds show one warning (`NETSDK1206`) about an Alpine-only SQLite library. You can ignore it on Ubuntu or WSL.

There are no tests and no linter.

### One-step setup scripts

Each app has a script that installs the .NET 8 SDK and ASP.NET Core 8 runtime if they are missing (user-local, in `~/.dotnet`), restores and builds the app, starts it in the background and health-checks the home page:

| App | Script | Default port |
|---|---|---|
| catalog | `./setup.sh` (repo root) | 5000 |
| inventory | `inventory/_setup_inventory.sh` | 5002 |
| cart | `cart/_setup_cart.sh` | 5004 |

All three take the same options:

```bash
./setup.sh                 # start on the default port, or the next free one
PORT=8080 ./setup.sh       # start on a specific port
./setup.sh --stop          # stop the app started by the script
```

State and logs go to `.setup/` next to each script. If the app is already running, the script says so and exits. The inventory and cart scripts also warn about placeholder settings in `appsettings.json`.

## Setup

Catalog needs no setup to run. Everything below is only needed to turn on the staged features. Settings live in each app's `appsettings.json`, which ships with placeholders — don't commit real values.

| Setting | Used by | Example format |
|---|---|---|
| `ConnectionStrings:BooksDB` | catalog (SQL mode), inventory, cart | SQL Server connection string |
| `Redis:ConnectionString` | catalog, cart | `<cache-key>@<cachename>.redis.cache.windows.net?ssl=True` |
| `OrderFunctionUrl` | cart | `http://<Function app name>.azurewebsites.net/api/ProcessOrderCosmos` |

### 1. Database (SQL Server / Azure SQL)

1. Set `ConnectionStrings:BooksDB` in the `appsettings.json` of each app that should use the database. All apps must point to the same database.
2. Create the `Books` table. Either apply the migration already checked in under `cart/Migrations`:
   ```bash
   cd cart
   dotnet ef database update
   ```
   or create one from catalog, as described in `catalog/connect_azure_sql.txt`:
   ```bash
   cd catalog
   dotnet ef migrations add -c BookContext InitialCreate
   dotnet ef database update
   ```
3. **catalog:** set `useInMemory = false` in `catalog/Startup.cs`.
4. **inventory:** uncomment the block marked `UNCOMMENT AFTER SETTING THE CONNECTION STRING` in `inventory/Pages/Index.cshtml.cs`.
5. **cart:** uncomment the line marked `UNCOMMENT AFTER WE HAVE A DATABASE` in `cart/Pages/Index.cshtml.cs` (this also needs Redis, step 2).
6. Open catalog and click **Load Books to DB** to seed the table.

### 2. Redis (shopping cart)

1. Set `Redis:ConnectionString` in `catalog/appsettings.json` and `cart/appsettings.json`.
2. **catalog:** uncomment the two blocks marked `UNCOMMENT AFTER ADDING REDIS` in `catalog/Pages/Index.cshtml.cs`.

For the cart to work across apps, catalog must also use the shared SQL database (step 1), not the in-memory one.

### 3. Order function (place order)

Set `OrderFunctionUrl` in `cart/appsettings.json` to an HTTP-triggered function that accepts the order JSON and returns `204 No Content`. The function itself is not in this repo.

## Run

```bash
cd catalog && dotnet run      # http://localhost:5000
cd inventory && dotnet run    # http://localhost:5002
cd cart && dotnet run         # http://localhost:5004
```

Each app uses the ports in its `Properties/launchSettings.json`, so all three can run at the same time (one terminal each). Or start them in the background with the [setup scripts](#one-step-setup-scripts).

What to expect before any setup:

- **catalog** — fully usable with the in-memory database. The list starts empty; click **Load Books to DB**. "Add to shopping cart" just reloads the page.
- **inventory** — the page loads but lists no books.
- **cart** — the page loads with an empty cart. The remove and place-order actions fail without SQL and Redis.

### cart in Docker

```bash
cd cart
docker build -t cart .
docker run -p 5004:5004 cart      # http://localhost:5004
```

### cart on Kubernetes

`cart/deployment.yaml` deploys the image `memicourseregistry.azurecr.io/cart:latest` behind a LoadBalancer service on port 80:

```bash
kubectl apply -f cart/deployment.yaml
```

### Publish

```bash
dotnet publish -c Release                 # run inside an app folder
```

## Notes

- **Version mismatch:** the EF Core packages are version 6.0.3 but the projects target .NET 8. The apps work as is, but upgrading the packages to 8.x would be cleaner.
- **HTTPS:** HTTPS redirection is commented out in all three apps, so the http URLs work directly.
- **Ignored files:** `.gitignore` excludes `bin/`, `obj/`, `.setup/` (state and logs from the setup scripts), and the publish output in `inventory/public/` and `inventory/app.zip`.
- **Images:** file names are case-sensitive on Linux. The catalog page references `images/cart.jpg` but the file is `cart.JPG`, and the seeded books point to cover images that are not in `wwwroot/images`.
- **Kubernetes port:** `cart/deployment.yaml` declares `containerPort: 80`, but the container listens on 5004. The Service's `targetPort: 5004` is what routes traffic.
