# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

"ReadIt!" book store, split into three independent ASP.NET Core Razor Pages apps (.NET 8), one per folder. They share no code — each has its own copy of `Book`, `BookContext`, layout and `wwwroot` — and integrate only through shared external state (the SQL `Books` table and a Redis list).

| App | Purpose | Local ports (http/https) | Runs without external services? |
|---|---|---|---|
| `catalog/` | Book list, "add to cart", weather page | 5000 / 5001 | Yes (in-memory DB) |
| `inventory/` | Edit `InStock` per book | 5002 / 5003 | Page renders; saving needs SQL |
| `cart/` | Shopping cart, place order | 5004 / 5005 | Page renders empty; handlers need SQL + Redis |

Front-end libraries (Bootstrap, jQuery, jQuery Validation) are committed under each app's `wwwroot/lib`; there is no Node/npm tooling.

## Commands

```bash
dotnet restore && dotnet build        # repo root: builds catalog ONLY (catalog-baseline-01.sln)
dotnet build cart/cart.csproj         # cart and inventory are not in the root solution
dotnet build inventory/inventory.csproj
cd <app> && dotnet run                # ports per the table above (Properties/launchSettings.json)
dotnet publish -c Release

./setup.sh                            # catalog only: installs .NET 8 if missing, builds, starts, health-checks
PORT=8080 ./setup.sh
./setup.sh --stop                     # state/logs in .setup/

cd cart && docker build -t cart .     # container listens on 5004
kubectl apply -f cart/deployment.yaml # image memicourseregistry.azurecr.io/cart:latest, LoadBalancer 80 -> 5004
```

catalog and cart builds emit one `NETSDK1206` warning (Alpine-only SQLite lib) — safe to ignore. There is no test project and no linter configured.

## Architecture

- **Hosting**: all three use old-style `Program.cs` + `Startup.cs` (generic host with `UseStartup<Startup>`), not minimal hosting. HTTPS redirection is commented out everywhere.
- **Shared state between apps**:
  - SQL `Books` table via the `BooksDB` connection string. catalog decrements `InStock` on add-to-cart, cart increments it on remove, inventory overwrites it.
  - Redis list `"cart"` holding book IDs as strings (`ServiceStack.Redis`, `Redis:ConnectionString`). catalog writes it; cart reads/removes/clears it.
  - cart `OnPostPlaceOrder` serializes an `Order` to JSON and POSTs it to an Azure Function at `OrderFunctionUrl`; the cart is cleared only on a `204 No Content` response.
- **DB provider selection**: catalog and cart have a hard-coded `Startup.useInMemory` flag (catalog `true`, cart `false`) choosing in-memory DB `"test"` vs. SQL Server. inventory is always SQL Server. Moving catalog to Azure SQL: flip the flag and follow `connect_azure_sql.txt` (`dotnet tool install --global dotnet-ef`, `dotnet ef migrations add -c BookContext InitialCreate`, `dotnet ef database update`). Only `cart/Migrations` has migrations checked in.
- **Staged "uncomment later" code**: this is course material, so features are deliberately commented out pending infrastructure. Look for the markers before assuming something is broken:
  - catalog `Index.cshtml.cs` — `UNCOMMENT AFTER ADDING REDIS` (cart count and add-to-cart; currently a no-op redirect).
  - cart `Index.cshtml.cs` — `UNCOMMENT AFTER WE HAVE A DATABASE` (`OnGet` always shows an empty cart; the remove/place-order handlers are live and will throw without SQL + Redis).
  - inventory `Index.cshtml.cs` — `UNCOMMENT AFTER SETTING THE CONNECTION STRING` (`OnGet` passes `null` books).
- **Seeding**: the DB starts empty. `BookLoader.LoadBooks` wipes and re-seeds four hard-coded books; it's triggered by the "load" form on catalog `/` (`OnPostLoad`). cart has a copy of `BookLoader` but nothing calls it.
- **Page handlers**: pages pass data to views via `ViewData` (`ViewData["books"]`, `ViewData["Error"]`, `ViewData["OrderStatus"]`) rather than bound model properties. Forms use `asp-page-handler="x"`, mapping to `OnPostX` methods; handlers read `Request.Form[...]` directly.
- **Weather page** (catalog): `OnPostWeather` makes a synchronous `HttpClient` GET to `http://{ip}/api/weather`, where `ip` comes from user input. It depends on a separate weather service that is not in this repo.
- `appsettings.json` files hold placeholder connection strings only.

## Gotchas

- `setup.sh` handles catalog only; it predates the cart and inventory apps.
- EF Core packages are pinned to 6.0.3 while the target framework is net8.0. It works; upgrading to 8.x would align them.
- `inventory/public/` and `inventory/app.zip` are checked-in publish output, not source. `inventory/.vscode/settings.json` points the Azure App Service extension at a specific subscription/slot.
- cart and inventory sources use CRLF line endings; catalog uses LF.
- `cart/deployment.yaml` declares `containerPort: 80` but the container listens on 5004 (the Service's `targetPort: 5004` is what actually routes).
- Static image paths are case-sensitive on Linux: catalog `Index.cshtml` references `~/images/cart.jpg` but the file is `cart.JPG`, and the seeded book `ImageUrl`s (`rama.jpg`, etc.) have no matching files in `wwwroot/images`.
- Files copied in from Windows under WSL can bring `*:Zone.Identifier` sidecar files; delete them.
