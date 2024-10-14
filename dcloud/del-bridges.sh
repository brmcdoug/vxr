#!/bin/bash

ip link set down ce1
ip link set down ce2

brctl delbr ce1
brctl delbr ce1

