// MWBFishData.h — 大肥鱼烘焙几何（YSM 一次性转换，运行时零解析零解码）
// 骨：parent 预解为下标（-1=根），轴心/旋转度数直传；盒：只烘焙几何，UV/贴图挂原版。
#pragma once
extern const int MWBFishBoneCount;
extern const int MWBFishBoneParent[];
extern const float MWBFishBonePivot[][3];
extern const float MWBFishBoneRot[][3];
extern const int MWBFishCubeCount;
extern const int MWBFishCubeBone[];
extern const float MWBFishCubeOrigin[][3];
extern const float MWBFishCubeSize[][3];
