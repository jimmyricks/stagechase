#define GL_SILENCE_DEPRECATION
#include <FFGL.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>

#include <dlfcn.h>

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

using PluginMain = FFMixed (*)(FFUInt32, FFMixed, FFInstanceID);

static constexpr GLsizei TestWidth = 1280;
static constexpr GLsizei TestHeight = 720;

static bool check(FFResult result, const char* operation)
{
    if (result == FF_SUCCESS) return true;
    std::cerr << operation << " failed with FFGL result " << result << "\n";
    return false;
}

static bool setParameter(PluginMain plugMain, FFInstanceID instance, unsigned int index, float value)
{
    SetParameterStruct parameter{};
    parameter.ParameterNumber = index;
    std::memcpy(&parameter.NewParameterValue.UIntValue, &value, sizeof(value));
    FFMixed input{};
    input.PointerValue = &parameter;
    return check(plugMain(FF_SET_PARAMETER, input, instance).UIntValue, "set parameter");
}

static std::vector<unsigned char> render(PluginMain plugMain, FFInstanceID instance, ProcessOpenGLStruct& process, GLuint framebuffer)
{
    FFMixed input{};
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glViewport(0, 0, TestWidth, TestHeight);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    input.PointerValue = &process;
    if (!check(plugMain(FF_PROCESS_OPENGL, input, instance).UIntValue, "render effect")) return {};
    glFinish();

    std::vector<unsigned char> pixels(TestWidth * TestHeight * 4);
    glReadPixels(0, 0, TestWidth, TestHeight, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    return pixels;
}

static size_t visiblePixels(const std::vector<unsigned char>& pixels, int x0, int y0, int x1, int y1)
{
    if (pixels.size() < static_cast<size_t>(TestWidth) * TestHeight * 4) return 0;
    size_t count = 0;
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            const size_t alpha = (static_cast<size_t>(y) * TestWidth + x) * 4 + 3;
            count += pixels[alpha] > 0;
        }
    }
    return count;
}

static bool hasVisiblePixelOnColumn(const std::vector<unsigned char>& pixels, int x, int y0, int y1)
{
    if (pixels.size() < static_cast<size_t>(TestWidth) * TestHeight * 4) return false;
    for (int y = y0; y < y1; ++y) {
        const size_t alpha = (static_cast<size_t>(y) * TestWidth + x) * 4 + 3;
        if (pixels[alpha] > 0) return true;
    }
    return false;
}

static double averageRed(const std::vector<unsigned char>& pixels, int x0, int y0, int x1, int y1)
{
    if (pixels.size() < static_cast<size_t>(TestWidth) * TestHeight * 4) return 0.0;
    double total = 0.0;
    size_t count = 0;
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            const size_t pixel = (static_cast<size_t>(y) * TestWidth + x) * 4;
            if (pixels[pixel + 3] == 0) continue;
            total += pixels[pixel];
            ++count;
        }
    }
    return count == 0 ? 0.0 : total / (255.0 * count);
}

static double redVariance(const std::vector<unsigned char>& pixels, int x0, int y0, int x1, int y1)
{
    if (pixels.size() < static_cast<size_t>(TestWidth) * TestHeight * 4) return 0.0;
    double total = 0.0;
    double squared = 0.0;
    size_t count = 0;
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            const size_t pixel = (static_cast<size_t>(y) * TestWidth + x) * 4;
            if (pixels[pixel + 3] == 0) continue;
            const double value = pixels[pixel] / 255.0;
            total += value;
            squared += value * value;
            ++count;
        }
    }
    if (count == 0) return 0.0;
    const double mean = total / count;
    return squared / count - mean * mean;
}

int main(int argc, char** argv)
{
    if (argc != 3) {
        std::cerr << "Usage: ffgl-render-smoke <plugin-bundle-executable> <chase|outline|bumper|wiper>\n";
        return 2;
    }
    const std::string kind = argv[2];
    if (kind != "chase" && kind != "outline" && kind != "bumper" && kind != "wiper") {
        std::cerr << "Unknown effect kind: " << kind << "\n";
        return 2;
    }
    const char* home = std::getenv("HOME");
    if (!home) {
        std::cerr << "HOME is not set\n";
        return 2;
    }
    const auto snapshotPath = std::filesystem::path(home) /
        "Library/Application Support/StageChase/LiveProject.stagechase-live";
    std::filesystem::create_directories(snapshotPath.parent_path());
    std::ofstream snapshot(snapshotPath);
    snapshot << "STAGECHASE 1\n"
             << "1080 1080\n"
             << "2\n"
             << "4\n0.05 0.1 0.5 0.1 0.5 0.9 0.05 0.9\n"
             << "4\n0.5 0.1 0.95 0.1 0.95 0.9 0.5 0.9\n"
             << "1\n"
             << "3 forward 0.45 fill 0\n"
             << "1 0\n"
             << "1 1\n"
             << "1 0\n";
    snapshot.close();
    if (!snapshot) {
        std::cerr << "Could not write the test project snapshot\n";
        return 1;
    }

    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile,
        static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_3_2_Core),
        kCGLPFAAccelerated,
        static_cast<CGLPixelFormatAttribute>(0)
    };
    CGLPixelFormatObj pixelFormat = nullptr;
    GLint pixelFormatCount = 0;
    if (CGLChoosePixelFormat(attributes, &pixelFormat, &pixelFormatCount) != kCGLNoError || !pixelFormat) {
        std::cerr << "Could not create an OpenGL 4.1 pixel format\n";
        return 1;
    }
    CGLContextObj context = nullptr;
    if (CGLCreateContext(pixelFormat, nullptr, &context) != kCGLNoError || !context) {
        CGLDestroyPixelFormat(pixelFormat);
        std::cerr << "Could not create an OpenGL context\n";
        return 1;
    }
    CGLSetCurrentContext(context);

    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        std::cerr << "Could not load FFGL bundle: " << dlerror() << "\n";
        return 1;
    }
    auto plugMain = reinterpret_cast<PluginMain>(dlsym(library, "plugMain"));
    if (!plugMain) {
        std::cerr << "FFGL bundle does not export plugMain\n";
        return 1;
    }

    FFMixed empty{};
    if (!check(plugMain(FF_INITIALISE_V2, empty, nullptr).UIntValue, "initialize FFGL")) return 1;
    FFGLViewportStruct viewport{0, 0, TestWidth, TestHeight};
    FFMixed viewportInput{};
    viewportInput.PointerValue = &viewport;
    FFMixed created = plugMain(FF_INSTANTIATE_GL, viewportInput, nullptr);
    if (!created.PointerValue || created.UIntValue == FF_FAIL) {
        std::cerr << "FFGL InitGL failed; shader or GL resource initialization was rejected\n";
        return 1;
    }
    FFInstanceID instance = created.PointerValue;
    std::this_thread::sleep_for(std::chrono::milliseconds(300));

    GLuint inputTexture = 0;
    GLuint outputTexture = 0;
    GLuint framebuffer = 0;
    glGenTextures(1, &inputTexture);
    glBindTexture(GL_TEXTURE_2D, inputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    std::vector<unsigned char> solid(TestWidth * TestHeight * 4, 255);
    for (int y = 0; y < TestHeight; ++y) {
        for (int x = 0; x < TestWidth; ++x) {
            const size_t index = (static_cast<size_t>(y) * TestWidth + x) * 4;
            solid[index] = static_cast<unsigned char>(255 * x / TestWidth);
            solid[index + 1] = static_cast<unsigned char>(255 * y / TestHeight);
            solid[index + 2] = 0;
            solid[index + 3] = 255;
        }
    }
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TestWidth, TestHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, solid.data());

    glGenTextures(1, &outputTexture);
    glBindTexture(GL_TEXTURE_2D, outputTexture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TestWidth, TestHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, outputTexture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        std::cerr << "Could not create test output framebuffer\n";
        return 1;
    }

    FFGLTextureStruct texture{TestWidth, TestHeight, TestWidth, TestHeight, inputTexture};
    FFGLTextureStruct* textures[] = {&texture};
    ProcessOpenGLStruct process{1, textures, framebuffer};
    auto set = [&](unsigned int index, float value) {
        return setParameter(plugMain, instance, index, value);
    };
    bool passed = true;
    if (kind == "chase") {
        passed = set(1, 0.0f);
        auto first = render(plugMain, instance, process, framebuffer);
        passed = passed && set(1, 0.1f);
        auto sameDiscreteStep = render(plugMain, instance, process, framebuffer);
        passed = passed && set(1, 0.5f);
        auto second = render(plugMain, instance, process, framebuffer);
        passed = passed && first == sameDiscreteStep &&
            visiblePixels(first, 64, 80, 640, 640) > 0 &&
            visiblePixels(first, 640, 80, 1216, 640) == 0 &&
            visiblePixels(second, 64, 80, 640, 640) == 0 &&
            visiblePixels(second, 640, 80, 1216, 640) > 0;
    } else if (kind == "outline") {
        passed = set(5, 0.0f);
        auto staticOutline = render(plugMain, instance, process, framebuffer);
        passed = passed && hasVisiblePixelOnColumn(staticOutline, TestWidth / 2, 80, 640);
        passed = passed && set(5, 1.0f) && set(6, 0.0f) && set(13, 2.0f);
        auto autoPhaseStart = render(plugMain, instance, process, framebuffer);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        auto autoPhaseMoved = render(plugMain, instance, process, framebuffer);
        passed = passed && autoPhaseStart != autoPhaseMoved;
        passed = passed && set(13, 0.0f) && set(6, 0.0f);
        auto phaseStart = render(plugMain, instance, process, framebuffer);
        passed = passed && set(6, 0.45f);
        auto phaseEnd = render(plugMain, instance, process, framebuffer);
        passed = passed && phaseStart != phaseEnd &&
            visiblePixels(phaseStart, 64, 80, 1216, 640) > 0 &&
            visiblePixels(phaseEnd, 64, 80, 1216, 640) > 0;
    } else if (kind == "bumper") {
        passed = set(6, 0.0f) && set(8, 5.0f);
        auto firstStep = render(plugMain, instance, process, framebuffer);
        passed = passed && visiblePixels(firstStep, 64, 80, 640, 640) > 0;
        passed = passed && set(2, 1.0f);
        auto secondStep = render(plugMain, instance, process, framebuffer);
        passed = passed && visiblePixels(secondStep, 64, 80, 640, 640) > 0 &&
            visiblePixels(secondStep, 640, 80, 1216, 640) > 0;
        passed = passed && set(3, 1.0f);
        auto previousStep = render(plugMain, instance, process, framebuffer);
        passed = passed && visiblePixels(previousStep, 64, 80, 640, 640) > 0 &&
            visiblePixels(previousStep, 640, 80, 1216, 640) > 0;
        for (int click = 0; click < 12 && passed; ++click) {
            passed = set(2, 1.0f);
            auto repeatedStep = render(plugMain, instance, process, framebuffer);
            passed = passed && visiblePixels(repeatedStep, 64, 80, 1216, 640) > 0;
        }
        passed = passed && set(2, 0.0f) && set(5, 30.0f) && set(8, 0.25f) && set(4, 1.0f);
        auto blastStarted = render(plugMain, instance, process, framebuffer);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        auto blastAdvanced = render(plugMain, instance, process, framebuffer);
        passed = passed && blastStarted != blastAdvanced &&
            visiblePixels(blastAdvanced, 64, 80, 1216, 640) > 0;
        passed = passed && set(4, 1.0f) && set(6, 1.0f) && set(7, 0.05f);
        render(plugMain, instance, process, framebuffer);
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        auto resetFrame = render(plugMain, instance, process, framebuffer);
        passed = passed && visiblePixels(resetFrame, 64, 80, 640, 640) > 0;
    } else {
        auto defaultWipe = render(plugMain, instance, process, framebuffer);
        passed = visiblePixels(defaultWipe, 64, 80, 640, 640) > 0;
        passed = passed && set(4, 0.0f) && set(2, 0.0f) && set(6, 0.0f) && set(1, 0.05f);
        auto earlyWipe = render(plugMain, instance, process, framebuffer);
        passed = passed && set(1, 0.2f);
        auto laterWipe = render(plugMain, instance, process, framebuffer);
        const size_t earlyCount = visiblePixels(earlyWipe, 64, 80, 640, 640);
        const size_t laterCount = visiblePixels(laterWipe, 64, 80, 640, 640);
        if (laterCount <= earlyCount)
            std::cerr << "Wiper progression did not reveal more content: " << earlyCount << " -> " << laterCount << "\n";
        passed = passed && laterCount > earlyCount;
        passed = passed && set(1, 0.2f) && set(3, 0.05f);
        auto shortWipe = render(plugMain, instance, process, framebuffer);
        passed = passed && set(3, 0.8f);
        auto longWipe = render(plugMain, instance, process, framebuffer);
        const size_t shortWipeCount = visiblePixels(shortWipe, 64, 80, 640, 640);
        const size_t longWipeCount = visiblePixels(longWipe, 64, 80, 640, 640);
        if (longWipeCount <= shortWipeCount)
            std::cerr << "Wiper Length did not widen the gradient: " << shortWipeCount << " -> " << longWipeCount << "\n";
        passed = passed && longWipeCount > shortWipeCount && set(3, 0.2f);
        passed = passed && set(4, 0.5f) && set(1, 0.2f);
        auto overlapFrame = render(plugMain, instance, process, framebuffer);
        const size_t overlapCurrent = visiblePixels(overlapFrame, 64, 80, 640, 640);
        const size_t overlapNext = visiblePixels(overlapFrame, 640, 80, 1216, 640);
        if (overlapCurrent == 0 || overlapNext == 0)
            std::cerr << "Wiper overlap visibility was " << overlapCurrent << " and " << overlapNext << "\n";
        passed = passed && overlapCurrent > 0 && overlapNext > 0;
        passed = passed && set(1, 0.8f);
        auto repeatedSliceOverlap = render(plugMain, instance, process, framebuffer);
        const size_t repeatedCount = visiblePixels(repeatedSliceOverlap, 64, 80, 640, 640);
        if (repeatedCount == 0)
            std::cerr << "Wiper repeated-slice overlap erased the current slice\n";
        passed = passed && repeatedCount > 0;
        passed = passed && set(4, 0.0f) && set(2, 0.0f) && set(1, 0.66f);
        auto fillFrame = render(plugMain, instance, process, framebuffer);
        passed = passed && set(2, 1.0f);
        auto maskFrame = render(plugMain, instance, process, framebuffer);
        const double fillRed = averageRed(fillFrame, 640, 80, 1216, 640);
        const double maskRed = averageRed(maskFrame, 640, 80, 1216, 640);
        const double fillVariance = redVariance(fillFrame, 640, 80, 1216, 640);
        const double maskVariance = redVariance(maskFrame, 640, 80, 1216, 640);
        if (std::abs(fillRed - maskRed) <= 0.08 || fillVariance >= maskVariance * 0.85)
            std::cerr << "Wiper UV mapping did not distinguish aspect-preserving Fill from Mask: means "
                      << fillRed << " / " << maskRed << ", variances " << fillVariance << " / " << maskVariance << "\n";
        passed = passed && std::abs(fillRed - maskRed) > 0.08 && fillVariance < maskVariance * 0.85;
        passed = passed && set(2, 0.0f) && set(6, 0.0f) && set(1, 0.1f);
        auto forwardWipe = render(plugMain, instance, process, framebuffer);
        passed = passed && set(6, 1.0f);
        auto reverseWipe = render(plugMain, instance, process, framebuffer);
        const size_t forwardBottom = visiblePixels(forwardWipe, 64, 80, 640, 260);
        const size_t forwardTop = visiblePixels(forwardWipe, 64, 420, 640, 640);
        const size_t reverseTop = visiblePixels(reverseWipe, 64, 420, 640, 640);
        const size_t reverseBottom = visiblePixels(reverseWipe, 64, 80, 640, 260);
        if (forwardBottom <= forwardTop || reverseTop <= reverseBottom)
            std::cerr << "Wiper direction mismatch: forward " << forwardBottom << " / " << forwardTop
                      << ", reverse " << reverseTop << " / " << reverseBottom << "\n";
        passed = passed && forwardBottom > forwardTop && reverseTop > reverseBottom;
    }

    if (!passed) {
        std::cerr << kind << " behavior check failed\n";
        return 1;
    }

    std::cout << "FFGL " << kind << " behavior check passed.\n";
    plugMain(FF_DEINSTANTIATE_GL, empty, instance);
    plugMain(FF_DEINITIALISE, empty, nullptr);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &inputTexture);
    glDeleteTextures(1, &outputTexture);
    dlclose(library);
    CGLSetCurrentContext(nullptr);
    CGLDestroyContext(context);
    CGLDestroyPixelFormat(pixelFormat);
    return 0;
}
