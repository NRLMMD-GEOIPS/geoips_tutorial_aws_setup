
import psutil
import time
import datetime
import matplotlib.pyplot as plt
import signal
import matplotlib.dates as mdates
import multiprocessing

SAMPLE_INTERVAL = 0.1  # seconds

timestamps = []
cpu_percentages = []
mem_used_gb = []
read_kbps = []
write_kbps = []
read_iops = []
write_iops = []

running = True

def signal_handler(sig, frame):
    global running
    print("\nKeyboard interrupt received. Stopping monitoring...")
    running = False

signal.signal(signal.SIGINT, signal_handler)

initial_io = psutil.disk_io_counters()
if initial_io is None:
    raise RuntimeError("Could not retrieve disk I/O counters. Ensure you're running in a full Linux environment.")

prev_read_bytes = initial_io.read_bytes
prev_write_bytes = initial_io.write_bytes
prev_read_count = initial_io.read_count
prev_write_count = initial_io.write_count
prev_time = time.time()

print("Monitoring started. Press Ctrl+C to stop...")

while running:
    now = datetime.datetime.now()
    timestamps.append(now)

    # Corrected CPU usage calculation: sum of per-core percentages
    cpu = sum(psutil.cpu_percent(interval=None, percpu=True))
    cpu_percentages.append(cpu)

    mem = psutil.virtual_memory().used / (1024 ** 3)  # in GB
    mem_used_gb.append(mem)

    time.sleep(SAMPLE_INTERVAL)

    curr_io = psutil.disk_io_counters()
    curr_time = time.time()
    elapsed = curr_time - prev_time

    if curr_io and elapsed > 0:
        read_rate = (curr_io.read_bytes - prev_read_bytes) / elapsed / 1024  # KB/s
        write_rate = (curr_io.write_bytes - prev_write_bytes) / elapsed / 1024  # KB/s
        read_ops = (curr_io.read_count - prev_read_count) / elapsed  # IOPS
        write_ops = (curr_io.write_count - prev_write_count) / elapsed  # IOPS
    else:
        read_rate = write_rate = read_ops = write_ops = 0

    read_kbps.append(read_rate)
    write_kbps.append(write_rate)
    read_iops.append(read_ops)
    write_iops.append(write_ops)

    prev_read_bytes = curr_io.read_bytes
    prev_write_bytes = curr_io.write_bytes
    prev_read_count = curr_io.read_count
    prev_write_count = curr_io.write_count
    prev_time = curr_time

print("Generating plots...")

fig, axes = plt.subplots(5, 1, figsize=(14, 12), sharex=True)

locator = mdates.AutoDateLocator()
formatter = mdates.ConciseDateFormatter(locator)

ncpus = multiprocessing.cpu_count()

axes[0].plot(timestamps, cpu_percentages, label='CPU Usage (%)', color='blue')
axes[0].axhline(ncpus * 100, color='gray', linestyle='--', label='Full CPU Capacity')
axes[0].set_ylabel('CPU (%)')
axes[0].set_title('System Monitoring Metrics Over Time')
axes[0].grid(True)
axes[0].legend()

axes[1].plot(timestamps, mem_used_gb, label='Memory Used (GB)', color='orange')
axes[1].set_ylabel('Memory (GB)')
axes[1].grid(True)
axes[1].legend()

axes[2].plot(timestamps, read_kbps, label='Disk Read (KB/s)', color='green')
axes[2].plot(timestamps, write_kbps, label='Disk Write (KB/s)', color='red')
axes[2].set_ylabel('KB/s')
axes[2].grid(True)
axes[2].legend()

axes[3].plot(timestamps, read_iops, label='Disk Read IOPS', color='purple')
axes[3].plot(timestamps, write_iops, label='Disk Write IOPS', color='brown')
axes[3].set_ylabel('IOPS')
axes[3].grid(True)
axes[3].legend()

axes[4].plot(timestamps, [r + w for r, w in zip(read_iops, write_iops)], label='Total IOPS', color='black')
axes[4].set_ylabel('Total IOPS')
axes[4].set_xlabel('Time')
axes[4].grid(True)
axes[4].legend()

axes[4].xaxis.set_major_locator(locator)
axes[4].xaxis.set_major_formatter(formatter)

plt.tight_layout()
plt.savefig("system_monitoring_plot_with_iops_finegrain.png")
plt.show()
