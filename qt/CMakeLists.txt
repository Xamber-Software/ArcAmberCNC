cmake_minimum_required(VERSION 3.22)
project(BetterLinuxCNC VERSION 0.2.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
include(GNUInstallDirs)
find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)
configure_file(app/betterlinuxcnc.in betterlinuxcnc @ONLY)
configure_file(app/betterlinuxcnc-service.in betterlinuxcnc-service @ONLY)

include(CTest)
if(BUILD_TESTING)
    find_package(Qt6 6.8 REQUIRED COMPONENTS Quick QuickControls2 QuickTest)
    qt_standard_project_setup(REQUIRES 6.8)
    qt_add_executable(qml-ui-tests tests/main.cpp)
    target_link_libraries(qml-ui-tests PRIVATE Qt6::QuickTest Qt6::QuickControls2)
    target_compile_definitions(qml-ui-tests PRIVATE
        QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
    add_test(NAME qml-ui COMMAND qml-ui-tests -import "${CMAKE_CURRENT_SOURCE_DIR}/qml")
    set_tests_properties(qml-ui PROPERTIES ENVIRONMENT
        "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software;QT_QUICK_CONTROLS_STYLE=Basic")
    add_test(NAME module-boundaries COMMAND Python3::Interpreter
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/check_boundaries.py")
    file(GLOB_RECURSE QML_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/qml/*.qml")
    add_test(NAME qml-lint COMMAND Qt6::qmllint --max-warnings 0
        -I "${CMAKE_CURRENT_SOURCE_DIR}/qml" ${QML_SOURCES})
    add_test(NAME python-integration COMMAND Python3::Interpreter -m unittest discover
        -s "${CMAKE_CURRENT_SOURCE_DIR}/tests/python" -v)
    set_tests_properties(python-integration PROPERTIES ENVIRONMENT
        "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}/python;QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software;QT_QUICK_CONTROLS_STYLE=Basic")
    add_test(NAME backend-integration COMMAND Python3::Interpreter -m unittest discover
        -s "${CMAKE_CURRENT_SOURCE_DIR}/../backend/tests" -v)
    set_tests_properties(backend-integration PROPERTIES ENVIRONMENT
        "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}/../backend/src")
    add_test(NAME desktop-startup COMMAND Python3::Interpreter
        "${CMAKE_CURRENT_SOURCE_DIR}/app/main.py" --smoke-test
        --socket "${CMAKE_CURRENT_BINARY_DIR}/no-controller-for-startup.sock")
    set_tests_properties(desktop-startup PROPERTIES ENVIRONMENT
        "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software;QT_QUICK_CONTROLS_STYLE=Basic"
        FAIL_REGULAR_EXPRESSION "QQmlApplicationEngine failed;ReferenceError:;TypeError:;Unable to assign;Binding loop detected")
endif()

install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/betterlinuxcnc" DESTINATION ${CMAKE_INSTALL_BINDIR})
install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/betterlinuxcnc-service" DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY python/bettercnc DESTINATION ${CMAKE_INSTALL_LIBDIR}/betterlinuxcnc/python
    PATTERN "__pycache__" EXCLUDE PATTERN "*.pyc" EXCLUDE)
install(DIRECTORY ../backend/src/ DESTINATION ${CMAKE_INSTALL_LIBDIR}/betterlinuxcnc/python
    PATTERN "__pycache__" EXCLUDE PATTERN "*.pyc" EXCLUDE PATTERN "*.egg-info" EXCLUDE)
install(DIRECTORY qml/ DESTINATION ${CMAKE_INSTALL_DATADIR}/betterlinuxcnc/qml)
install(FILES packaging/betterlinuxcnc-qt.desktop DESTINATION share/applications)
install(FILES ../COPYING qml/BetterCnc/Catalog/assets/NOTICE.md
    qml/BetterCnc/Catalog/assets/TOOLBAR-LICENSE DESTINATION share/doc/betterlinuxcnc-qt)
set(CPACK_PACKAGE_NAME "betterlinuxcnc-qt")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_PACKAGE_CONTACT "BetterLinuxCNC maintainers")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Native PySide6/QML desktop for LinuxCNC")
set(CPACK_DEBIAN_PACKAGE_ARCHITECTURE "all")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "python3 (>= 3.11), python3-pyside6.qtcore (>= 6.8), python3-pyside6.qtgui, python3-pyside6.qtqml, python3-pyside6.qtquick, python3-pyside6.qtquickcontrols2, linuxcnc-uspace (>= 2.9), python3-opengl, qml6-module-qtqml, qml6-module-qtqml-models, qml6-module-qtquick, qml6-module-qtquick-window, qml6-module-qtquick-controls, qml6-module-qtquick-layouts, qml6-module-qtquick-templates, qml6-module-qtquick-shapes, qml6-module-qtquick-dialogs, qml6-module-qtqml-workerscript, fonts-noto-cjk, fonts-liberation")
include(CPack)
