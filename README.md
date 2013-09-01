netsync
---
a network synchronization tool that:
- maps network interfaces to their respective (potentially stacked) devices
- gathers interface-specific information from an asset management database
- sends the information it gathers to each device

Note: All communication with network nodes is done using SNMP, and the database is assumed to track devices by serial number.

netsync also provides ways of producing useful information about the network.  
For an in-depth description of netsync, see [doc/netsync.txt](https://github.com/dmtucker/netsync/blob/master/doc/netsync.txt).
