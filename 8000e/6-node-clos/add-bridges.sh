#!/bin/bash

sudo brctl addbr ceos1-l01
sudo brctl addbr ceos2-l02
sudo ip link set ceos1-l01 up
sudo ip link set ceos2-l02 up