#!/usr/bin/env python3
"""Rebuild the studio environment's equirectangular image, Models/N72Studio.png (NumPy, Pillow); DeviceModelView
builds the RealityKit environment from it at run time.

Broad cool reflection bands describe the rolled chrome. A front softbox's
lower edge gives the concave Home button its dark-to-light falloff.
Radiance is stored at quarter intensity; DeviceModelView restores two stops.
"""
import numpy as np
from pathlib import Path
w,h=512,256
u,v=np.meshgrid((np.arange(w)+.5)/w,(np.arange(h)+.5)/h)
lon=(u-.5)*2*np.pi;lat=(.5-v)*np.pi
rz=np.cos(lat)*np.cos(lon);ry=np.sin(lat)
band=np.exp(-((rz+.1)/.32)**2)
front=np.clip((ry+.12)/.12,0,1);front=front*front*(3-2*front)
light=.005+1.5*band+2*front*np.clip((abs(rz)-.9)/.08,0,1)
rgb=light[...,None]*np.array([.92,.96,1.])
from PIL import Image
ldr=np.clip(rgb/4,0,1)
srgb=np.where(ldr<=.0031308,12.92*ldr,1.055*ldr**(1/2.4)-.055)
Image.fromarray(np.uint8(srgb * 255)).save(Path(__file__).resolve().parents[1] / "Models/N72Studio.png")
