for i in $(seq 1 20); do
  curl -s -o /dev/null -w "req $i: %{http_code} %{time_total}s\n" \
       "http://localhost:8080/https://httpbin.org/delay/2" &
  curl -s -o /dev/null -w "gh  $i: %{http_code} %{time_total}s\n" \
       "http://localhost:8080/https://api.github.com/zen" &
done
wait
