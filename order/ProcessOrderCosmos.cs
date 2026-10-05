using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using System.Text.Json;
using System.Collections.Generic;
using Microsoft.Azure.Functions.Worker;

namespace AzureCourse.Function
{    
    public class CosmosOrderFunction
    {
        private readonly ILogger<CosmosOrderFunction> _logger;

        public CosmosOrderFunction(ILogger<CosmosOrderFunction> logger)
        {
            _logger = logger;
        }

        [Function("ProcessOrderCosmos")]
        //[CosmosDBOutput(databaseName: "readit-orders", containerName: "orders", Connection = "CosmosDBConnection",CreateIfNotExists =true)]            
        public object Run(
            [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = null)] HttpRequest req)            
        {
            string requestBody = new StreamReader(req.Body).ReadToEndAsync().Result;

            _logger.LogInformation($"Order JSON: {requestBody}");

            return "OK";
            //var order=JsonSerializer.Deserialize<Order>(requestBody, new JsonSerializerOptions { PropertyNameCaseInsensitive = true })??new Order();
            //order.id=Guid.NewGuid().ToString();
            //return order;
        }
    }
}

