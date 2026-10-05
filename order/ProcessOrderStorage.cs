using Microsoft.Azure.WebJobs;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using System.Threading.Tasks;
using System;
using System.IO;
using System.Text.Json;
using System.Collections.Generic;
using Microsoft.Azure.Storage.Blob;
using Microsoft.Azure.Functions.Worker;

namespace AzureCourse.Function
{
    public class EventGridFunction
    {
        private readonly ILogger<EventGridFunction> _logger;

        public EventGridFunction(ILogger<EventGridFunction> logger)
        {
            _logger = logger;
        }

        [Function("ProcessOrderStorage")]
        //[BlobOutput("orders/{rand-guid}.txt",Connection = "StorageConnectionString")]
        public string Run(
            [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = null)] HttpRequest req)
        {
            string requestBody = new StreamReader(req.Body).ReadToEndAsync().Result;

            _logger.LogInformation($"Order received: {requestBody}");

            return requestBody;
        }
    }
}

    