#!/bin/bash

brctl addbr ce1
brctl addbr ce1

ip link set up ce1
ip link set up ce2