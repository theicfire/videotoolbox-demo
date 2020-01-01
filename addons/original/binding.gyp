{
    "target_defaults": {
        "default_configuration": "Release",
        "configurations": {
            "Debug": {
                "defines": ["DEBUG"],
            },
        },
    },
    "targets": [{
        "target_name": "addon",
        "cflags!": ["-fno-exceptions"],
        "cflags_cc!": ["-fno-exceptions"],
        "cflags_cc": ["-Wall", "-Wuninitialized"],
        "xcode_settings": {
            "OTHER_CFLAGS": [
                "-std=c++17",
                "-stdlib=libc++",
                "-Wno-delete-non-virtual-dtor", # TODO cheat. Ignore a warning for now.
            ],
            "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
            "MACOSX_DEPLOYMENT_TARGET": "10.14", # Otherwise seeing an error like "was built for newer OSX version (10.14) than being linked (10.7)"
        },
        "sources": [
            "cppsrc/main.cpp",
            "cppsrc/window.cpp",
            # "cppsrc/h264_player.cpp",
        ],
        "include_dirs": [
            "<!@(node -p \"require('node-addon-api').include\")",
        ],
        "dependencies": [
            "<!(node -p \"require('node-addon-api').gyp\")"
        ],
        "defines": [
            "NAPI_CPP_EXCEPTIONS=1",
        ],
        "conditions": [
            ["OS == 'mac'", {
                "libraries": [
                    "-framework AppKit",
                    "-framework CoreVideo",
                    "-framework CoreMedia",
                    "-framework CoreGraphics",
                    "-framework VideoToolbox",
                    "/System/Library/Frameworks/ApplicationServices.framework",
                    "<(module_root_dir)/lib/mac/libSDL2.a",
                    "<(module_root_dir)/lib/mac/libvpx.a",
                    "<(module_root_dir)/lib/mac/libxvidcore.a",
                    "<(module_root_dir)/lib/mac/libx264.a",
                    "<(module_root_dir)/lib/mac/libx265.a",
                    "<(module_root_dir)/lib/mac/libaom.a",
                    "<(module_root_dir)/lib/mac/libspeex.a",
                    "<(module_root_dir)/lib/mac/libavcodec.a",
                    "<(module_root_dir)/lib/mac/libavformat.a",
                    "<(module_root_dir)/lib/mac/libavdevice.a",
                    "<(module_root_dir)/lib/mac/libavutil.a",
                    "<(module_root_dir)/lib/mac/libswscale.a",
                ]
            }]
        ]
    }]
}
