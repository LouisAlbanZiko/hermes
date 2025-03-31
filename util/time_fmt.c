#include <time_fmt.h>

size_t timestamp_to_iso8601(int64_t us, char *buffer, size_t buffer_size) {
	time_t sec = us / 1000000;
	int64_t sec_us = us % 1000000;

	struct tm *tm_info = localtime(&sec);

	size_t len = strftime(buffer, buffer_size, "%Y-%m-%dT%H:%M:%S", tm_info);
	len += snprintf(buffer + len, buffer_size - len, ".%06ldZ", sec_us);
	
	return len;
}
