#ifndef SPRITE_VERTEX_LIGHTING_INCLUDED
#define SPRITE_VERTEX_LIGHTING_INCLUDED
	
#include "ShaderShared.cginc"
#include "SpriteLighting.cginc"
#include "UnityStandardUtils.cginc"

////////////////////////////////////////
// Defines
//

//Define to use spot lights (more expensive)
#define SPOT_LIGHTS

//Have to process lighting per pixel if using normal maps or a diffuse ramp or rim lighting
#if defined(_NORMALMAP) || defined(_DIFFUSE_RAMP) || defined(_RIM_LIGHTING)
#define PER_PIXEL_LIGHTING
#endif

//Turn off bump mapping and diffuse ramping on older shader models as they dont support needed number of outputs
#if defined(PER_PIXEL_LIGHTING) && (SHADER_TARGET < 30)
	#undef PER_PIXEL_LIGHTING
	#undef _NORMALMAP
	#undef _DIFFUSE_RAMP
	#undef _RIM_LIGHTING
#endif

//In D3D9 only have a max of 9 TEXCOORD so can't have diffuse ramping or fog or rim lighting if processing lights per pixel
#if defined(SHADER_API_D3D9) && defined(PER_PIXEL_LIGHTING)
	#if defined(_NORMALMAP)
		#undef _DIFFUSE_RAMP
		#undef _FOG
		#undef _RIM_LIGHTING
	#elif defined(_DIFFUSE_RAMP)
		#undef _FOG
		#undef _RIM_LIGHTING
	#elif defined(_RIM_LIGHTING)
		#undef _FOG
		#undef _DIFFUSE_RAMP
	#else
		#undef _DIFFUSE_RAMP
		#undef _RIM_LIGHTING
	#endif
#endif

#if defined(PER_PIXEL_LIGHTING)
	#if defined(_NORMALMAP) && defined(_DIFFUSE_RAMP)
		#define ATTENUATIONS TEXCOORD9
		#if defined(_RIM_LIGHTING)
			#define _POS_WORLD_INDEX TEXCOORD10
			#define _FOG_COORD_INDEX 11
		#else
			#define _FOG_COORD_INDEX 10
		#endif
	#elif defined(_NORMALMAP) != defined(_DIFFUSE_RAMP)
		#define ATTENUATIONS TEXCOORD8
		#if defined(_RIM_LIGHTING)
			#define _POS_WORLD_INDEX TEXCOORD9
			#define _FOG_COORD_INDEX 10
		#else
			#define _FOG_COORD_INDEX 9
		#endif
	#else //!_DIFFUSE_RAMP && !_NORMALMAP
		#if defined(_RIM_LIGHTING)
			#define _POS_WORLD_INDEX TEXCOORD8
			#define _FOG_COORD_INDEX 9
		#else
			#define _FOG_COORD_INDEX 8
		#endif
	#endif
#else //!PER_PIXEL_LIGHTING
	#define _FOG_COORD_INDEX 2
#endif

////////////////////////////////////////
// Vertex output struct
//

struct VertexOutput
{
	float4 pos : SV_POSITION;				
	fixed4 color : COLOR;
	float3 texcoord : TEXCOORD0;
	
#if defined(PER_PIXEL_LIGHTING)

	half4 VertexLightInfo0 : TEXCOORD1; 
	half4 VertexLightInfo1 : TEXCOORD2;
	half4 VertexLightInfo2 : TEXCOORD3;  
	half4 VertexLightInfo3 : TEXCOORD4;
	half4 VertexLightInfo4 : TEXCOORD5;
	
	#if defined(_NORMALMAP)
		half4 normalWorld : TEXCOORD6;
		half4 tangentWorld : TEXCOORD7;
		half4 binormalWorld : TEXCOORD8;
	#else
		half3 normalWorld : TEXCOORD6;
		half3 VertexLightInfo5 : TEXCOORD7;  
	#endif
	#if defined(_DIFFUSE_RAMP)
		half4 LightAttenuations : ATTENUATIONS;
	#endif
	#if defined(_RIM_LIGHTING)
		float4 posWorld : _POS_WORLD_INDEX;
	#endif

#else //!PER_PIXEL_LIGHTING

	half3 FullLighting : TEXCOORD1; 
	
#endif // !PER_PIXEL_LIGHTING

#if defined(_FOG)
	UNITY_FOG_COORDS(_FOG_COORD_INDEX)
#endif // _FOG
};

////////////////////////////////////////
// Light calculations
//

struct VertexLightInfo
{
	half3 lightDirection;
	fixed3 lightColor;
	
#if defined(_DIFFUSE_RAMP)	
	float attenuationSqrt;
#endif // _DIFFUSE_RAMP
};

inline VertexLightInfo getVertexLightAttenuatedInfo(int index, float3 viewPos)
{
	VertexLightInfo lightInfo;
	
	//For directional lights _WorldSpaceLightPos0.w is set to zero
	lightInfo.lightDirection = unity_LightPosition[index].xyz - viewPos.xyz * unity_LightPosition[index].w;
	float lengthSq = dot(lightInfo.lightDirection, lightInfo.lightDirection);
	
	// don't produce NaNs if some vertex position overlaps with the light
	lengthSq = max(lengthSq, 0.000001);
		
	lightInfo.lightDirection *= rsqrt(lengthSq);
	
	float attenuation = 1.0 / (1.0 + lengthSq * unity_LightAtten[index].z);	
	
#if defined(SPOT_LIGHTS)
	//Spot light attenuation - for non-spot lights unity_LightAtten.x is set to -1 and y is set to 1
	{
		float rho = max (0, dot(lightInfo.lightDirection, unity_SpotDirection[index].xyz));
		float spotAtt = (rho - unity_LightAtten[index].x) * unity_LightAtten[index].y;
		attenuation *= saturate(spotAtt);
	}
#endif // SPOT_LIGHTS
	
	//If using a diffuse ramp texture then need to pass through the lights attenuation, otherwise premultiply the light color with it
#if defined(_DIFFUSE_RAMP)	
	lightInfo.lightColor = unity_LightColor[index].rgb;
	lightInfo.attenuationSqrt = sqrt(attenuation);
#else
	lightInfo.lightColor = unity_LightColor[index].rgb * attenuation;
#endif // _DIFFUSE_RAMP
	
	return lightInfo;
}

fixed3 calculateAmbientLight(half3 normalWorld)
{
#if defined(_SPHERICAL_HARMONICS)	

	//Magic constants used to tweak ambient to approximate pixel shader spherical harmonics 
	static const fixed3 worldUp = fixed3(0,1,0);
	static const float skyGroundDotMul = 2.5;
	static const float minEquatorMix = 0.5;
	static const float equatorColorBlur = 0.33;
	
	float upDot = dot(normalWorld, worldUp);
	
	//Fade between a flat lerp from sky to ground and a 3 way lerp based on how bright the equator light is.
	//This simulates how directional lights get blurred using spherical harmonics
	
	//Work out color from ground and sky, ignoring equator
	float adjustedDot = upDot * skyGroundDotMul;
	fixed3 skyGroundColor = lerp(unity_AmbientGround, unity_AmbientSky, saturate((adjustedDot + 1.0) * 0.5));
	
	//Work out equator lights brightness
	float equatorBright = saturate(dot(unity_AmbientEquator.rgb, unity_AmbientEquator.rgb));
	
	//Blur equator color with sky and ground colors based on how bright it is.
	fixed3 equatorBlurredColor = lerp(unity_AmbientEquator, saturate(unity_AmbientEquator + unity_AmbientGround + unity_AmbientSky), equatorBright * equatorColorBlur);
	
	//Work out 3 way lerp inc equator light
	fixed3 equatorColor = lerp(equatorBlurredColor, unity_AmbientGround, -upDot) * step(upDot, 0) + lerp(equatorBlurredColor, unity_AmbientSky, upDot) * step(0, upDot);
	
	//Mix the two colors together based on how bright the equator light is
	return lerp(skyGroundColor, equatorColor, saturate(equatorBright + minEquatorMix)) * 0.75;

#else // !_SPHERICAL_HARMONICS

	//Flat ambient is just the sky color
	return unity_AmbientSky.rgb * 0.75;
	
#endif // !_SPHERICAL_HARMONICS	
}

////////////////////////////////////////
// Light Packing Functions (this stuff gets messy!)
//

#if defined(_DIFFUSE_RAMP)

inline fixed3 calculateLightDiffuse(fixed3 lightColor, half3 normal, half3 lightDirection, float attenuation)
{
	float angleDot = max(0, dot(normal, lightDirection));
	fixed3 diffuse = calculateRampedDiffuse(lightColor, attenuation, angleDot);
	return diffuse;
}

#else

inline fixed3 calculateLightDiffuse(fixed3 attenuatedLightColor, half3 normal, half3 lightDirection)
{
	float angleDot = max(0, dot(normal, lightDirection));
	fixed3 diffuse = attenuatedLightColor * angleDot;
	return diffuse;
}

#endif // _NORMALMAP


#if defined(PER_PIXEL_LIGHTING)

inline VertexLightInfo getVertexLightAttenuatedInfoWorldSpace(int index, float3 viewPos)
{
	VertexLightInfo lightInfo = getVertexLightAttenuatedInfo(index, viewPos);
	
	//Convert light direction from view space to world space
	lightInfo.lightDirection = normalize(mul((float3x3)UNITY_MATRIX_V, lightInfo.lightDirection));
	
	return lightInfo;
}
	
#define VERTEX_LIGHT_0_DIR VertexLightInfo0.xyz
#define VERTEX_LIGHT_0_R VertexLightInfo4.x
#define VERTEX_LIGHT_0_G VertexLightInfo4.y
#define VERTEX_LIGHT_0_B VertexLightInfo4.z

#define VERTEX_LIGHT_1_DIR  VertexLightInfo1.xyz
#define VERTEX_LIGHT_1_R VertexLightInfo0.w
#define VERTEX_LIGHT_1_G VertexLightInfo1.w
#define VERTEX_LIGHT_1_B VertexLightInfo2.w

#define VERTEX_LIGHT_2_DIR VertexLightInfo2.xyz
#define VERTEX_LIGHT_2_R VertexLightInfo3.w
#define VERTEX_LIGHT_2_G VertexLightInfo4.w
#define VERTEX_LIGHT_2_B texcoord.z

#define VERTEX_LIGHT_3_DIR VertexLightInfo3.xyz

#if defined(_NORMALMAP)
	#define VERTEX_LIGHT_3_R normalWorld.w
	#define VERTEX_LIGHT_3_G tangentWorld.w
	#define VERTEX_LIGHT_3_B binormalWorld.w
#else
	#define VERTEX_LIGHT_3_R VertexLightInfo5.x
	#define VERTEX_LIGHT_3_G VertexLightInfo5.y
	#define VERTEX_LIGHT_3_B VertexLightInfo5.z
#endif
	
#if defined(_DIFFUSE_RAMP)

	#define LIGHT_DIFFUSE_ATTEN_0 LightAttenuations.x
	#define LIGHT_DIFFUSE_ATTEN_1 LightAttenuations.y
	#define LIGHT_DIFFUSE_ATTEN_2 LightAttenuations.z
	#define LIGHT_DIFFUSE_ATTEN_3 LightAttenuations.w

	#define PACK_VERTEX_LIGHT_DIFFUSE(index, output, lightInfo) \
	{ \
		output.LIGHT_DIFFUSE_ATTEN_##index = lightInfo.attenuationSqrt; \
	}
	
	#define ADD_VERTEX_LIGHT_DIFFUSE(index, diffuse, input, vertexLightColor, normalDirection, vertexLightDir) \
	{ \
		diffuse += calculateLightDiffuse(vertexLightColor, normalDirection, vertexLightDir, input.LIGHT_DIFFUSE_ATTEN_##index); \
	}
#else
	#define PACK_VERTEX_LIGHT_DIFFUSE(index, output, lightInfo)
	#define ADD_VERTEX_LIGHT_DIFFUSE(index, diffuse, input, vertexLightColor, normalDirection, vertexLightDir) \
	{ \
		diffuse += calculateLightDiffuse(vertexLightColor, normalDirection, vertexLightDir); \
	}
#endif

#define PACK_VERTEX_LIGHT(index, output, viewPos) \
	{ \
		VertexLightInfo lightInfo = getVertexLightAttenuatedInfoWorldSpace(index, viewPos); \
		output.VERTEX_LIGHT_##index##_DIR = lightInfo.lightDirection; \
		output.VERTEX_LIGHT_##index##_R = lightInfo.lightColor.r; \
		output.VERTEX_LIGHT_##index##_G = lightInfo.lightColor.g; \
		output.VERTEX_LIGHT_##index##_B = lightInfo.lightColor.b; \
		PACK_VERTEX_LIGHT_DIFFUSE(index, output, lightInfo); \
	}

#define ADD_VERTEX_LIGHT(index, input, normalDirection, diffuse) \
	{ \
		half3 vertexLightDir = input.VERTEX_LIGHT_##index##_DIR; \
		fixed3 vertexLightColor = fixed3(input.VERTEX_LIGHT_##index##_R, input.VERTEX_LIGHT_##index##_G, input.VERTEX_LIGHT_##index##_B); \
		ADD_VERTEX_LIGHT_DIFFUSE(index, diffuse, input, vertexLightColor, normalDirection, vertexLightDir) \
	}

#else //!PER_PIXEL_LIGHTING

////////////////////////////////////////
// Vertex Only Functions
//

inline fixed3 calculateLightDiffuse(int index, float3 viewPos, half3 viewNormal)
{
	VertexLightInfo lightInfo = getVertexLightAttenuatedInfo(index, viewPos);
	float diff = max (0, dot (viewNormal, lightInfo.lightDirection));
	return lightInfo.lightColor * diff;
}

#endif // !PER_PIXEL_LIGHTING
	
////////////////////////////////////////
// Vertex program
//

VertexOutput vert(VertexInput input)
{
	VertexOutput output;
	
	output.pos = calculateLocalPos(input.vertex);
	output.color = calculateVertexColor(input.color);
	output.texcoord = float3(calculateTextureCoord(input.texcoord), 0);
	
	float3 viewPos = mul(UNITY_MATRIX_MV, input.vertex);

#if defined(PER_PIXEL_LIGHTING)
	
	#if defined(_RIM_LIGHTING)
		output.posWorld = calculateWorldPos(input.vertex);
	#endif

	PACK_VERTEX_LIGHT(0, output, viewPos)
	PACK_VERTEX_LIGHT(1, output, viewPos)
	PACK_VERTEX_LIGHT(2, output, viewPos)
	PACK_VERTEX_LIGHT(3, output, viewPos)
	
	output.normalWorld.xyz = calculateSpriteWorldNormal(input);
	
	#if defined(_NORMALMAP)
		output.tangentWorld.xyz = calculateWorldTangent(input.tangent);
		output.binormalWorld.xyz = calculateSpriteWorldBinormal(output.normalWorld, output.tangentWorld, input.tangent.w);	
	#endif
	
#else // !PER_PIXEL_LIGHTING
	
	//Just pack full lighting
	float3 viewNormal = calculateSpriteViewNormal(input);
	
	//Get Ambient diffuse
	float3 normalWorld = calculateSpriteWorldNormal(input);
	fixed3 ambient = calculateAmbientLight(normalWorld);
	
	fixed3 diffuse = calculateLightDiffuse(0, viewPos, viewNormal);
	diffuse += calculateLightDiffuse(1, viewPos, viewNormal);
	diffuse += calculateLightDiffuse(2, viewPos, viewNormal);
	diffuse += calculateLightDiffuse(3, viewPos, viewNormal);
	
	output.FullLighting = ambient + diffuse;
	
#endif // !PER_PIXEL_LIGHTING
	
#if defined(_FOG)
	UNITY_TRANSFER_FOG(output, output.pos);
#endif // _FOG	
		
	return output;
}

////////////////////////////////////////
// Fragment program
//

fixed4 frag(VertexOutput input) : SV_Target
{
	fixed4 texureColor = calculateTexturePixel(input.texcoord.xy);
	ALPHA_CLIP(texureColor, input.color)
	
#if defined(PER_PIXEL_LIGHTING)
	
	#if defined(_NORMALMAP)
		half3 normalWorld = calculateNormalFromBumpMap(input.texcoord.xy, input.tangentWorld.xyz, input.binormalWorld.xyz, input.normalWorld.xyz);
	#else
		half3 normalWorld = input.normalWorld.xyz;
	#endif
	
	//Get Ambient diffuse
	fixed3 ambient = calculateAmbientLight(normalWorld);
	
	//Find vertex light diffuse
	fixed3 diffuse = fixed3(0,0,0);
	
	//Add each vertex light to diffuse
	ADD_VERTEX_LIGHT(0, input, normalWorld, diffuse)
	ADD_VERTEX_LIGHT(1, input, normalWorld, diffuse)
	ADD_VERTEX_LIGHT(2, input, normalWorld, diffuse)
	ADD_VERTEX_LIGHT(3, input, normalWorld, diffuse)
	
	fixed3 lighting = ambient + diffuse;
	
	APPLY_EMISSION(lighting, input.texcoord.xy)

	fixed4 pixel = calculateLitPixel(texureColor, input.color, lighting);
	
#if defined(_RIM_LIGHTING)
	pixel.rgb = applyRimLighting(input.posWorld, normalWorld, pixel);
#endif
	
#else // !PER_PIXEL_LIGHTING
	
	APPLY_EMISSION(input.FullLighting, input.texcoord.xy)
	
	fixed4 pixel = calculateLitPixel(texureColor, input.color, input.FullLighting);

#endif // !PER_PIXEL_LIGHTING	
	
	COLORISE(pixel)
	
#if defined(_FOG)
	fixed4 fogColor = lerp(fixed4(0,0,0,0), unity_FogColor, pixel.a);
	UNITY_APPLY_FOG_COLOR(input.fogCoord, pixel, fogColor);
#endif // _FOG	
	
	return pixel;
}

#endif // SPRITE_VERTEX_LIGHTING_INCLUDED