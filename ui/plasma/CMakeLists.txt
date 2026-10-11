cmake_minimum_required(VERSION 3.21)
project(omega-notch-plasma VERSION 0.0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml Network)
find_package(LayerShellQt REQUIRED)

qt_standard_project_setup(REQUIRES 6.5)
qt_policy(SET QTP0001 NEW)
qt_policy(SET QTP0004 NEW)

qt_add_executable(omega-notch-plasma
    src/main.cpp
    src/engineclient.cpp
    src/engineclient.h
    src/notifications.cpp
    src/notifications.h
)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(omega-notch-plasma
    URI OmegaNotch
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/NotchShape.qml
        qml/ProviderRing.qml
        qml/ProviderGlyph.qml
        qml/DetailCard.qml
        qml/UsageRow.qml
        qml/TokenPanel.qml
        qml/ChatRow.qml
        qml/ToolButton.qml
        qml/SettingsWindow.qml
        qml/SettingsSwitch.qml
        qml/SettingsSegmented.qml
        qml/SettingsButton.qml
        qml/CopilotSignIn.qml
)

target_compile_definitions(omega-notch-plasma PRIVATE OMEGA_NOTCH_VERSION="${PROJECT_VERSION}")

target_link_libraries(omega-notch-plasma PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    LayerShellQt::Interface
)

install(TARGETS omega-notch-plasma RUNTIME DESTINATION bin)
