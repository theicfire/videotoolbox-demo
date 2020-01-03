#pragma once

#include <chrono>
#include <string>
#include <vector>

namespace custom
{
    struct FrameStatistics {
        int index;
        double decodingTime;
        double renderingTime;
    };

    class PlayerStatistics {
    public:
        PlayerStatistics();

        void startFrame();
        void endFrame();

        void startDecoding();
        void endDecoding();

        void startRendering();
        void endRendering();

        std::vector<FrameStatistics> getFrameStatistics();

    private:
        std::chrono::high_resolution_clock::time_point m_time;
        std::vector<FrameStatistics> m_frames;
        int m_index;
        FrameStatistics m_currentFrame;
    };

    class VTBPlayer {
    public:
        explicit VTBPlayer();
        ~VTBPlayer();
        void play(const std::string& path);

        std::vector<FrameStatistics> getFrameStatistics();

    private:
        void open(const std::string& path);

        // PImpl
        struct Context;
        Context* m_context;
    };
}
