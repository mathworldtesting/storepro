# ReadIt! book store

Three independent ASP.NET Core Razor Pages apps on .NET 8, one per folder:

| App | What it does | Local URL | Needs to run locally |
|---|---|---|---|
| `catalog/` | Lists books, "add to shopping cart", weather page (`/Weather`) | http://localhost:5000 (https 5001) | Nothing — uses an in-memory database |
| `inventory/` | Edits the stock count of each book | http://localhost:5002 (https 5003) | SQL Server / Azure SQL |
| `cart/` | Shows the shopping cart, removes items, places an order | http://localhost:5004 (https 5005) | SQL Server / Azure SQL, Redis, and an order-processing Azure Function |

The apps share no code. Each has its own copy of the `Book` model, `BookContext` and `wwwroot`. They work together through shared external services:

- **SQL `Books` table** (`ConnectionStrings:BooksDB`) — catalog lowers `InStock` when a book is added to the cart, cart raises it when a book is removed, inventory sets it directly.
- **Redis list `cart`** (`Redis:ConnectionString`) — catalog adds book IDs, cart reads and removes them.
- **Azure Function** (`OrderFunctionUrl`) — cart posts the order as JSON and empties the cart when the function answers `204 No Content`.

There are no Node or Python dependencies. The front-end libraries (Bootstrap, jQuery, jQuery Validation) are committed under each app's `wwwroot/lib`.

## Prerequisites

- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0). Tested with 8.0.416, 8.0.420 and 8.0.421.
- Optional: Docker and `kubectl` for the cart container, and the EF Core CLI for database migrations:
  ```bash
  dotnet tool install --global dotnet-ef
  ```

## Build

The solution file in the repo root (`catalog-baseline-01.sln`) contains only catalog, so build the other two by project:

```bash
dotnet build                              # catalog
dotnet build inventory/inventory.csproj
dotnet build cart/cart.csproj
```

The catalog and cart builds show one warning (`NETSDK1206`) about an Alpine-only SQLite library. You can ignore it on Ubuntu or WSL.

There are no tests and no linter.

## Run

```bash
cd catalog && dotnet run      # or inventory, or cart
```

Each app uses the ports in its `Properties/launchSettings.json` (see the table above), so all three can run at the same time.

### catalog

Runs with no setup. `Startup.cs` sets `useInMemory = true`, so it uses an in-memory database that starts empty; click **Load Books to DB** on the home page to seed four books.

"Add to shopping cart" does nothing until Redis is turned on: fill in `Redis:ConnectionString` in `appsettings.json` and uncomment the blocks marked `UNCOMMENT AFTER ADDING REDIS` in `Pages/Index.cshtml.cs`.

The `/Weather` page calls `http://<address you enter>/api/weather` on a separate weather service that is not in this repo.

`setup.sh` in the repo root automates catalog only: it installs the .NET 8 SDK if missing, builds, starts the app and health-checks it.

```bash
./setup.sh                 # start on port 5000, or the next free port
PORT=8080 ./setup.sh
./setup.sh --stop
```

### inventory

Always uses SQL Server. Set `ConnectionStrings:BooksDB` in `appsettings.json`, then uncomment the block marked `UNCOMMENT AFTER SETTING THE CONNECTION STRING` in `Pages/Index.cshtml.cs`. Until then the page loads but lists no books.

### cart

`Startup.cs` sets `useInMemory = false`, so it expects SQL Server. Fill in `ConnectionStrings:BooksDB`, `Redis:ConnectionString` and `OrderFunctionUrl` in `appsettings.json`, then uncomment the line marked `UNCOMMENT AFTER WE HAVE A DATABASE` in `Pages/Index.cshtml.cs`. Until then the page loads with an empty cart.

To run it in a container (listens on port 5004):

```bash
cd cart
docker build -t cart .
docker run -p 5004:5004 cart
```

`cart/deployment.yaml` deploys the image `memicourseregistry.azurecr.io/cart:latest` to Kubernetes behind a LoadBalancer service on port 80:

```bash
kubectl apply -f cart/deployment.yaml
```

## Switching catalog to Azure SQL

Set `useInMemory = false` in `catalog/Startup.cs`, fill in `ConnectionStrings:BooksDB`, then follow `catalog/connect_azure_sql.txt`:

```bash
cd catalog
dotnet ef migrations add -c BookContext InitialCreate
dotnet ef database update
```

`cart/Migrations` already contains an `InitialCreate` migration for the same table.

## Notes

- **Version mismatch:** the EF Core packages are version 6.0.3 but the projects target .NET 8. The apps work as is, but upgrading the packages to 8.x would be cleaner.
- **Connection strings:** the `appsettings.json` files contain placeholders only. Don't commit real values.
- **Ignored files:** `.gitignore` excludes `bin/`, `obj/`, `.setup/` (state and logs from `setup.sh`), and the publish output in `inventory/public/` and `inventory/app.zip`.
- **Images:** file names are case-sensitive on Linux. The catalog page references `images/cart.jpg` but the file is `cart.JPG`, and the seeded books point to cover images that are not in `wwwroot/images`.
# storepro
# storepro
# storepro
# storepro
