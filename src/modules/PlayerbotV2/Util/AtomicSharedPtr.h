// AtomicSharedPtr - a shared_ptr slot that one thread publishes and others read, with load()/store() like
// std::atomic<std::shared_ptr<T>>.
//
// std::atomic<std::shared_ptr<T>> (C++20, P0718) is in MSVC's and GCC's standard libraries, but not in libc++, the
// standard library of Apple clang on macOS: there std::atomic<T> needs a trivially copyable T and the build stops.
// Where the library has it (__cpp_lib_atomic_shared_ptr) this is exactly that type. Elsewhere a small lock guards the
// pointer, which is what MSVC's and libstdc++'s own implementations do inside (neither is lock-free): a reader gets its
// own counted copy, so a later store only drops a reference and never frees what a reader still holds.

#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <utility>

namespace Playerbot {

#if defined(__cpp_lib_atomic_shared_ptr) && __cpp_lib_atomic_shared_ptr >= 201711L

template <typename T>
using AtomicSharedPtr = std::atomic<std::shared_ptr<T>>;

#else

template <typename T>
class AtomicSharedPtr
{
public:
    AtomicSharedPtr() noexcept = default;
    explicit AtomicSharedPtr(std::shared_ptr<T> p) noexcept : ptr_(std::move(p)) {}
    AtomicSharedPtr(AtomicSharedPtr const&) = delete;
    AtomicSharedPtr& operator=(AtomicSharedPtr const&) = delete;

    std::shared_ptr<T> load(std::memory_order = std::memory_order_seq_cst) const
    {
        std::lock_guard<std::mutex> lock(mtx_);
        return ptr_;
    }

    void store(std::shared_ptr<T> p, std::memory_order = std::memory_order_seq_cst)
    {
        // The old object is released after the lock is dropped, so its destructor never runs under the lock.
        std::shared_ptr<T> old;
        {
            std::lock_guard<std::mutex> lock(mtx_);
            old = std::exchange(ptr_, std::move(p));
        }
    }

    std::shared_ptr<T> exchange(std::shared_ptr<T> p, std::memory_order = std::memory_order_seq_cst)
    {
        std::lock_guard<std::mutex> lock(mtx_);
        return std::exchange(ptr_, std::move(p));
    }

    operator std::shared_ptr<T>() const { return load(); }
    void operator=(std::shared_ptr<T> p) { store(std::move(p)); }

    static constexpr bool is_always_lock_free = false;
    bool is_lock_free() const noexcept { return false; }

private:
    mutable std::mutex mtx_;
    std::shared_ptr<T> ptr_;
};

#endif

} // namespace Playerbot
