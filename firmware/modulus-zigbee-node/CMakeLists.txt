cmake_minimum_required(VERSION 3.22)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
idf_build_set_property(MINIMAL_BUILD ON)
set(PROJECT_VER "3.1.4-dev")
project(modulus_zigbee_node)
