## Replication Tests

### set up data
```
shred -n 1 -s 0 - 1>tmp/0b
shred -n 1 -s 1M - 1>tmp/1M 
shred -n 1 -s 129M - 1>tmp/129M
```

### one way replication between 2-zones -> 1-zone
./setup.sh
./quick_tests.sh

### two way replication between 2-zones -> 1-zone
./2waysetup.sh
./quick_tests.sh
