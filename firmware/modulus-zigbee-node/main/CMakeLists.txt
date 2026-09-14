idf_component_register(
    SRCS "main.c" "node_config.c" "node_temperature.c"
    INCLUDE_DIRS "."
    PRIV_REQUIRES nvs_flash esp_driver_gpio ieee802154 app_update
)
