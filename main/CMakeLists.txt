idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    EMBED_TXTFILES "phone.html"
    REQUIRES esp_wifi esp_netif esp_event esp_http_server bt nvs_flash
)