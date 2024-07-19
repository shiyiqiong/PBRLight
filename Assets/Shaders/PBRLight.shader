Shader "Custom/PBRLight"
{
    Properties
    {
        _BaseMap("Texture", 2D) = "white" {} //基础颜色贴图
        _BaseColor("Color", Color) = (0.5, 0.5, 0.5, 1.0) //基础颜色
        _Metallic("Metallic", Range(0, 1)) = 0 //金属性
        _Smoothness("Smoothness", Range(0, 1)) = 0.5 //光滑度
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        Pass
        {
            Name "ForwardLit"
            Tags
            {
                "LightMode" = "UniversalForward"
            }
            HLSLPROGRAM
            #pragma multi_compile_instancing
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/UnityInstancing.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"

            #define MIN_REFLECTIVITY 0.04 //最小反射率

            struct appdata
            {
                float3 vertex : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
                float3 positionWS : VAR_POSITION;
                half3 normalWS : VAR_NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            sampler2D _BaseMap;

            UNITY_INSTANCING_BUFFER_START(UnityPerMaterial)
                UNITY_DEFINE_INSTANCED_PROP(float4, _BaseMap_ST)
                UNITY_DEFINE_INSTANCED_PROP(float4, _BaseColor)
                UNITY_DEFINE_INSTANCED_PROP(float, _Metallic)
                UNITY_DEFINE_INSTANCED_PROP(float, _Smoothness)
            UNITY_INSTANCING_BUFFER_END(UnityPerMaterial)

            //环境光：通过球谐光照参数和法线向量计算
            float3 AmbientLight(half3 normalWS, float3 color)
            {
                float4 coefficients[7];
                coefficients[0] = unity_SHAr;
                coefficients[1] = unity_SHAg;
                coefficients[2] = unity_SHAb;
                coefficients[3] = unity_SHBr;
                coefficients[4] = unity_SHBg;
                coefficients[5] = unity_SHBb;
                coefficients[6] = unity_SHC;
                return max(0.0, SampleSH9(coefficients, normalWS)) * color;
            }

            //平方函数
            float Square(float v)
            {
                return v * v;
            }

            //1减于反射率（0-0.96）
            float OneMinusReflectivity(float metallic)
            {
                float range = 1.0 - MIN_REFLECTIVITY;
                return range - metallic*range;
            }

            //漫反射双向反射分布函数
            float3 DiffuseBRDF(float3 color)
            {
                float metallic = UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _Metallic);
                float oneMinusReflectivity = OneMinusReflectivity(metallic);
                return color * oneMinusReflectivity;
            }

            //镜面反射双向反射分布函数
            float3 SeqcularBRDF(half3 normalWS, float3 positionWS, float3 color)
            {
                float metallic = UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _Metallic); //金属性
                float3 specularColor = lerp(MIN_REFLECTIVITY, color, metallic); //镜面反射颜色
                float smoothness = UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _Smoothness);
                float perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(smoothness);  //感知粗糙度
                float roughness = PerceptualRoughnessToRoughness(perceptualRoughness); //粗糙度
                half3 mainLightDir = half3(_MainLightPosition.xyz); //主光照方向
                half3 mainLightColor = _MainLightColor.rgb; //主光照颜色
                half3 viewDirWS = GetWorldSpaceNormalizeViewDir(positionWS); //视角向量

                float3 h = SafeNormalize(mainLightDir + viewDirWS);
                float nh2 = Square(saturate(dot(normalWS, h)));
                float lh2 = Square(saturate(dot(mainLightDir, h)));
                float r2 = Square(roughness);
                float d2 = Square(nh2 * (r2 - 1.0) + 1.00001);
                float normalization = roughness *4.0 + 2.0;
                float seqcularStrength = r2 / (d2 * max(0.1, lh2) * normalization); //镜面反射强度
                return seqcularStrength * specularColor;
            }

            //直射光双向反射分布函数：镜面反射双向反射分布函数加上漫反射双向反射分布函数
            float3 DirectBRDF(half3 normalWS, float3 positionWS, float3 color)
            {
                float3 diffuseBRDF = DiffuseBRDF(color);
                float3 seqcularBRDF = SeqcularBRDF(normalWS, positionWS, color);
                return seqcularBRDF + diffuseBRDF;
            }

            //接收到光照
            float3 IncomingLight(half3 normalWS)
            {
                half3 mainLightDir = half3(_MainLightPosition.xyz); //主光照方向
                half3 mainLightColor = _MainLightColor.rgb; //主光照颜色
                return saturate(dot(normalWS, mainLightDir)) * mainLightColor; 
            }

            //直射光：接收到光照乘以直射光双向反射分布函数
            float3 Directlight(half3 normalWS, float3 positionWS, float3 color)
            {
                return IncomingLight(normalWS) * DirectBRDF(normalWS, positionWS, color);
            }

            v2f vert (appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                //顶点计算
                o.positionWS = TransformObjectToWorld(v.vertex); //顶点：模型空间转世界空间
                o.vertex = TransformWorldToHClip(o.positionWS); //顶点：世界空间转齐次裁剪空间
                //法线计算
                o.normalWS = TransformObjectToWorldNormal(v.normalOS); //法线向量：模型空间转世界空间
                //UV坐标计算
                float4 baseMapST = UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _BaseMap_ST);
                o.uv = v.uv * baseMapST.xy + baseMapST.zw; //纹理UV坐标：加上缩放和平移参数
                return o;
            }

            float4 frag (v2f i) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                float4 col = tex2D(_BaseMap, i.uv);
                float4 baseColor = UNITY_ACCESS_INSTANCED_PROP(UnityPerMaterial, _BaseColor);
                col = col * baseColor;
                //环境光
                float3 ambient = AmbientLight(i.normalWS, col.rgb);
                //直射光
                float3 directlight = Directlight(i.normalWS, i.positionWS, col.rgb);
                //最终光照
                return float4(ambient + directlight, col.a);
            }

            ENDHLSL
        }
    }
}
