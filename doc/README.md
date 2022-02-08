# CDR - *Call Detail Records*

When calls finish, the CDR app receives the `CHANNEL_DESTROY` event, massages some of the values, then stores the CDR to the account's MODB.


### Interpreting jitter stats on CDRs

As per the media engine vendor:

* Quality percent is a factor of how many packets you get as expected. If you lose multiple in a row it adds a penalty.
* MOS is just scaling 100% down to a scale of 0-4 or something.
* Any of the other stuff like jitter percent etc was added by community consistent with the standards for those fields
  * https://www.voiptroubleshooter.com/indepth/burstloss.html
  * https://en.wikipedia.org/wiki/Packet_delay_variation
* Packet counts and jitter seem like OK calculations. mostly the quality and MOS is suspect. Probably only applies to g.711 since some other codecs can hide problems better.
* Packet loss calls are before any attempt to fix it is done with fec etc. Or jitter buffer.
* Jitter buffer can fix the jitter or cure minor burst loss. That just means you don't lose many packets but it doesn't promise it sounds good.
