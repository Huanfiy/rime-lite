// pauserank.cpp — fcitx5 停顿重排插件（D-30；结构见 docs/design/pause-rank.md，构建与运维见 ../README.md）
//
// 流程（全部在 fcitx5 主循环，不阻塞；普通按键只多一次计时器重置）：
//   1. 观察真实按键；停顿 kPauseUs 且当前 IC 为 rime、有候选、高亮在首页首项 → 向 IC 注入 F33。
//      rime 侧 pause_rank.processor 同步写出候选快照 $XDG_RUNTIME_DIR/rime-pause-rank/req。
//   2. 把 req 原样转发给打分服务（ranker.sock），非阻塞连接，计时器轮询收包。
//   3. 回包 "<ver>\t<best>\t<ms>"：best > 0 且期间无任何真实按键 → 写 res，注入 F34；
//      rime 侧校验版本 / 段身份 / 高亮后刷新组句，pause_rank.filter 把首选提到同跨度首位。
// 注入经 InputContext::keyEvent 直达输入法，不走前端转发：未被消费也不会漏到应用。
// 任意真实按键 / 失焦立即作废在途请求，晚到结果不会改写用户已看到的候选。

#include <fcitx-utils/event.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/trackableobject.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr uint64_t kPauseUs = 200000;     // 停顿判定
constexpr uint64_t kPollUs = 5000;        // 在途请求收包轮询间隔
constexpr uint64_t kTimeoutUs = 1500000;  // 在途请求超时（含整段上文重算的冷启动）
constexpr uint64_t kAccuracyUs = 1000;     // 计时精度；sd-event 传 0 会退回默认 250ms 合并窗口
constexpr auto kSnap = static_cast<fcitx::KeySym>(0xFFDE);   // F33
constexpr auto kApply = static_cast<fcitx::KeySym>(0xFFDF);  // F34

uint64_t monoNow() { return fcitx::now(CLOCK_MONOTONIC); }

std::string readFile(const std::string &path) {
    std::ifstream in(path);
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

class PauseRank final : public fcitx::AddonInstance {
public:
    explicit PauseRank(fcitx::Instance *instance) : instance_(instance) {
        const char *rt = getenv("XDG_RUNTIME_DIR");
        dir_ = std::string(rt && *rt ? rt : "/tmp") + "/rime-pause-rank";
        mkdir(dir_.c_str(), 0700);

        auto &loop = instance_->eventLoop();
        pauseTimer_ = loop.addTimeEvent(CLOCK_MONOTONIC, monoNow(), kAccuracyUs,
                                        [this](fcitx::EventSourceTime *, uint64_t) {
                                            onPause();
                                            return true;
                                        });
        pauseTimer_->setEnabled(false);
        pollTimer_ = loop.addTimeEvent(CLOCK_MONOTONIC, monoNow(), kAccuracyUs,
                                       [this](fcitx::EventSourceTime *, uint64_t) {
                                           onPoll();
                                           return true;
                                       });
        pollTimer_->setEnabled(false);

        handlers_.emplace_back(instance_->watchEvent(
            fcitx::EventType::InputContextKeyEvent,
            fcitx::EventWatcherPhase::PreInputMethod, [this](fcitx::Event &event) {
                onKey(static_cast<fcitx::KeyEvent &>(event));
            }));
        handlers_.emplace_back(instance_->watchEvent(
            fcitx::EventType::InputContextFocusOut,
            fcitx::EventWatcherPhase::PostInputMethod,
            [this](fcitx::Event &) { bump(); }));
        log("start");
    }

    ~PauseRank() override { dropRequest(); }

private:
    void onKey(fcitx::KeyEvent &event) {
        if (injecting_) {
            return;
        }
        const auto &key = event.rawKey();
        if (event.isRelease()) {
            // 修饰键释放可能改状态（左 Shift 点按翻转中英），作废在途请求；普通键释放不影响 rime 状态
            if (key.isModifier()) {
                modHeld_ = false;
                bump();
            }
            return;
        }
        bump();
        if (key.isModifier()) {
            modHeld_ = true;
            return;
        }
        modHeld_ = key.states().testAny(fcitx::KeyStates{
            fcitx::KeyState::Ctrl, fcitx::KeyState::Alt, fcitx::KeyState::Super});
        ic_ = event.inputContext()->watch();
        pauseTimer_->setTime(monoNow() + kPauseUs);
        pauseTimer_->setOneShot();
    }

    // 有任何真实按键 / 失焦：停计时、作废在途请求
    void bump() {
        pauseTimer_->setEnabled(false);
        dropRequest();
    }

    // 当前 IC 仍可安全改候选：有焦点、rime、高亮在首页首项
    fcitx::InputContext *eligibleIC() {
        auto *ic = ic_.get();
        if (!ic || !ic->hasFocus() || modHeld_ || instance_->inputMethod(ic) != "rime") {
            return nullptr;
        }
        auto cl = ic->inputPanel().candidateList();
        if (!cl || cl->size() < 2 || cl->cursorIndex() > 0) {
            return nullptr;
        }
        if (auto *pg = cl->toPageable(); pg && pg->hasPrev()) {
            return nullptr;
        }
        return ic;
    }

    bool inject(fcitx::InputContext *ic, fcitx::KeySym sym) {
        injecting_ = true;
        fcitx::KeyEvent event(ic, fcitx::Key(sym));
        bool accepted = ic->keyEvent(event);
        injecting_ = false;
        return accepted;
    }

    void onPause() {
        auto *ic = eligibleIC();
        if (!ic) {
            return;
        }
        const auto req = dir_ + "/req";
        unlink(req.c_str());
        const auto t0 = monoNow();
        if (!inject(ic, kSnap)) {
            log("snap key not accepted");
            return;
        }
        auto body = readFile(req);
        if (body.empty()) {
            return;  // rime 侧判定无需重排（候选不足 / 本段已重排 / 高亮已动）
        }
        sendRequest(body, t0);
    }

    void sendRequest(std::string body, uint64_t t0) {
        dropRequest();
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
        if (fd < 0) {
            return;
        }
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        const auto path = dir_ + "/ranker.sock";
        if (path.size() >= sizeof(addr.sun_path)) {
            ::close(fd);
            return;
        }
        std::memcpy(addr.sun_path, path.c_str(), path.size() + 1);
        if (body.back() != '\n') {
            body.push_back('\n');
        }
        if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0 ||
            write(fd, body.data(), body.size()) != static_cast<ssize_t>(body.size())) {
            const int err = errno;
            ::close(fd);
            if (monoNow() > nextUnavailableLog_) {
                nextUnavailableLog_ = monoNow() + 60000000;
                log(std::string("ranker unavailable: ") + std::strerror(err));
            }
            return;
        }
        fd_ = fd;
        reqStart_ = t0;
        rx_.clear();
        pollTimer_->setTime(monoNow() + kPollUs);
        pollTimer_->setOneShot();
    }

    void dropRequest() {
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
        pollTimer_->setEnabled(false);
        rx_.clear();
    }

    void onPoll() {
        if (fd_ < 0) {
            return;
        }
        char buf[512];
        bool eof = false;
        for (;;) {
            ssize_t n = read(fd_, buf, sizeof(buf));
            if (n > 0) {
                rx_.append(buf, n);
                continue;
            }
            if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                eof = true;
            }
            break;
        }
        const auto nl = rx_.find('\n');
        if (nl == std::string::npos) {
            if (eof || monoNow() - reqStart_ > kTimeoutUs) {
                log(eof ? "ranker closed without reply" : "ranker timeout");
                dropRequest();
                return;
            }
            pollTimer_->setTime(monoNow() + kPollUs);
            pollTimer_->setOneShot();
            return;
        }
        const auto line = rx_.substr(0, nl);
        const auto dtMs = (monoNow() - reqStart_) / 1000;
        dropRequest();
        onReply(line, dtMs);
    }

    void onReply(const std::string &line, uint64_t dtMs) {
        unsigned long ver = 0;
        int best = 0;
        double lmMs = 0;
        if (std::sscanf(line.c_str(), "%lu\t%d\t%lf", &ver, &best, &lmMs) < 2) {
            log("bad reply: " + line);
            return;
        }
        if (best <= 0) {
            log("keep ver=" + std::to_string(ver) + " pause→reply=" + std::to_string(dtMs) + "ms");
            return;
        }
        auto *ic = eligibleIC();
        if (!ic) {
            log("drop ver=" + std::to_string(ver) + " (ic no longer eligible)");
            return;
        }
        {
            std::ofstream out(dir_ + "/res", std::ios::trunc);
            out << line << '\n';
        }
        inject(ic, kApply);
        log("apply ver=" + std::to_string(ver) + " best=" + std::to_string(best) +
            " pause→apply=" + std::to_string((monoNow() - reqStart_) / 1000) + "ms");
    }

    void log(const std::string &msg) {
        const auto path = dir_ + "/plugin.log";
        struct stat st {};
        if (stat(path.c_str(), &st) == 0 && st.st_size > (1 << 20)) {
            unlink(path.c_str());
        }
        if (FILE *f = std::fopen(path.c_str(), "a")) {
            std::fprintf(f, "%.3f %s\n", monoNow() / 1e6, msg.c_str());
            std::fclose(f);
        }
    }

    fcitx::Instance *instance_;
    std::string dir_;
    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>> handlers_;
    std::unique_ptr<fcitx::EventSourceTime> pauseTimer_, pollTimer_;
    fcitx::TrackableObjectReference<fcitx::InputContext> ic_;
    uint64_t reqStart_ = 0;
    uint64_t nextUnavailableLog_ = 0;
    int fd_ = -1;
    std::string rx_;
    bool injecting_ = false;
    bool modHeld_ = false;
};

class PauseRankFactory : public fcitx::AddonFactory {
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new PauseRank(manager->instance());
    }
};

}  // namespace

FCITX_ADDON_FACTORY(PauseRankFactory);
