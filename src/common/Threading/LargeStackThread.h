/*
 * This file is part of the TrinityCore Project. See AUTHORS file for Copyright information
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef TRINITYCORE_LARGE_STACK_THREAD_H
#define TRINITYCORE_LARGE_STACK_THREAD_H

// A std::thread with a large stack on every platform.
//
// macOS gives a std::thread only 512 KB of stack (Linux 8 MB, Windows 1 MB), and std::thread cannot be told otherwise.
// The map update threads and the bot worker pools run deep call chains (bot AI, path finding, spell and aura code), so on
// macOS they start through pthread with kStackSize; everywhere else this is a plain std::thread. join(), joinable(),
// detach() and the destructor behave like std::thread's.

#include <cstddef>
#include <exception>
#include <functional>
#include <memory>
#include <thread>
#include <tuple>
#include <type_traits>
#include <utility>

#if defined(__APPLE__)
#include <pthread.h>
#include <system_error>
#endif

namespace Trinity
{
class LargeStackThread
{
public:
    static constexpr std::size_t kStackSize = 8 * 1024 * 1024;   // Linux's default

    LargeStackThread() noexcept = default;

    template <typename F, typename... Args,
              typename = std::enable_if_t<!std::is_same_v<std::decay_t<F>, LargeStackThread>>>
    explicit LargeStackThread(F&& f, Args&&... args)
    {
        Start([fn = std::forward<F>(f), tup = std::make_tuple(std::forward<Args>(args)...)]() mutable
        {
            std::apply([&fn](auto&... a) { std::invoke(fn, a...); }, tup);
        });
    }

    LargeStackThread(LargeStackThread const&) = delete;
    LargeStackThread& operator=(LargeStackThread const&) = delete;

    LargeStackThread(LargeStackThread&& other) noexcept { *this = std::move(other); }
    LargeStackThread& operator=(LargeStackThread&& other) noexcept
    {
        if (this != &other)
        {
            if (joinable())
                std::terminate();   // as std::thread
#if defined(__APPLE__)
            _handle = other._handle;
            _running = other._running;
            other._running = false;
#else
            _thread = std::move(other._thread);
#endif
        }
        return *this;
    }

    ~LargeStackThread()
    {
        if (joinable())
            std::terminate();   // as std::thread
    }

#if defined(__APPLE__)
    bool joinable() const noexcept { return _running; }
    void join()
    {
        if (!_running)
            throw std::system_error(std::make_error_code(std::errc::invalid_argument), "LargeStackThread::join");
        pthread_join(_handle, nullptr);
        _running = false;
    }
    void detach()
    {
        if (!_running)
            throw std::system_error(std::make_error_code(std::errc::invalid_argument), "LargeStackThread::detach");
        pthread_detach(_handle);
        _running = false;
    }
#else
    bool joinable() const noexcept { return _thread.joinable(); }
    void join() { _thread.join(); }
    void detach() { _thread.detach(); }
#endif

private:
#if defined(__APPLE__)
    void Start(std::function<void()> body)
    {
        auto* heapBody = new std::function<void()>(std::move(body));
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, kStackSize);
        int const err = pthread_create(&_handle, &attr, &LargeStackThread::Entry, heapBody);
        pthread_attr_destroy(&attr);
        if (err != 0)
        {
            delete heapBody;
            throw std::system_error(err, std::system_category(), "LargeStackThread: pthread_create");
        }
        _running = true;
    }

    static void* Entry(void* arg) noexcept
    {
        std::unique_ptr<std::function<void()>> body(static_cast<std::function<void()>*>(arg));
        (*body)();   // noexcept: an exception that escapes ends the process, as with std::thread
        return nullptr;
    }

    pthread_t _handle{};
    bool _running = false;
#else
    template <typename Body>
    void Start(Body&& body) { _thread = std::thread(std::forward<Body>(body)); }

    std::thread _thread;
#endif
};
}

#endif // TRINITYCORE_LARGE_STACK_THREAD_H
